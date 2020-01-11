UidGenerator
==========================
[In English](README.md)

UidGenerator是Java实现的, 基于[Snowflake](https://github.com/twitter/snowflake)算法的唯一ID生成器。UidGenerator以组件形式工作在应用项目中,
支持自定义workerId位数和初始化策略, 从而适用于[docker](https://www.docker.com/)等虚拟化环境下实例自动重启、漂移等场景。
在实现上, UidGenerator通过借用未来时间来解决sequence天然存在的并发限制; 采用RingBuffer来缓存已生成的UID, 并行化UID的生产和消费,
同时对CacheLine补齐，避免了由RingBuffer带来的硬件级「伪共享」问题. 最终单机QPS可达<font color=red>600万</font>。

依赖版本：[Java8](http://www.oracle.com/technetwork/java/javase/downloads/jdk8-downloads-2133151.html)及以上版本,
[MySQL](https://dev.mysql.com/downloads/mysql/)(内置WorkerID分配器, 启动阶段通过DB进行分配; 如自定义实现, 则DB非必选依赖）

Snowflake算法
-------------
| sign  |  delta seconds   |  worker node id   |  sequence   |
|:---:|:---:|:---:|:---:|
|  1bit | 32bits    |  18bits   |  13bits   |

Snowflake算法描述：指定机器 & 同一时刻 & 某一并发序列，是唯一的。据此可生成一个64 bits的唯一ID（long）。默认采用上图字节分配方式：

* sign(1bit)  
  固定1bit符号标识，即生成的UID为正数。

* delta seconds (32 bits)  
  当前时间，相对于时间基点"2020-01-01"的增量值，单位：秒，最多可支持约136年

* worker id (18 bits)  
  机器id，最多可支持约26w台不同ip的机器部署。内置实现为在启动时由数据库分配，默认分配策略为根据ip复用workid

* sequence (13 bits)   
  每秒下的并发序列，13 bits可支持每秒8192个并发。
  
**以上参数均可通过Spring进行自定义**


CachedUidGenerator
-------------------
RingBuffer环形数组，数组每个元素成为一个slot。RingBuffer容量，默认为Snowflake算法中sequence最大值，且为2^N。可通过```boostPower```配置进行扩容，以提高RingBuffer
读写吞吐量。

Tail指针、Cursor指针用于环形数组上读写slot：

* Tail指针  
  表示Producer生产的最大序号(此序号从0开始，持续递增)。Tail不能超过Cursor，即生产者不能覆盖未消费的slot。当Tail已赶上curosr，此时可通过```rejectedPutBufferHandler```指定PutRejectPolicy
  
* Cursor指针  
  表示Consumer消费到的最小序号(序号序列与Producer序列相同)。Cursor不能超过Tail，即不能消费未生产的slot。当Cursor已赶上tail，此时可通过```rejectedTakeBufferHandler```指定TakeRejectPolicy

![RingBuffer](doc/ringbuffer.png)  

CachedUidGenerator采用了双RingBuffer，Uid-RingBuffer用于存储Uid、Flag-RingBuffer用于存储Uid状态(是否可填充、是否可消费)

由于数组元素在内存中是连续分配的，可最大程度利用CPU cache以提升性能。但同时会带来「伪共享」FalseSharing问题，为此在Tail、Cursor指针、Flag-RingBuffer中采用了CacheLine
补齐方式。

![FalseSharing](doc/cacheline_padding.png) 

#### RingBuffer填充时机 ####
* 初始化预填充  
  RingBuffer初始化时，预先填充满整个RingBuffer.
  
* 即时填充  
  Take消费时，即时检查剩余可用slot量(```tail``` - ```cursor```)，如小于设定阈值，则补全空闲slots。阈值可通过```paddingFactor```来进行配置，请参考Quick Start中CachedUidGenerator配置
  
* 周期填充  
  通过Schedule线程，定时补全空闲slots。可通过```scheduleInterval```配置，以应用定时填充功能，并指定Schedule时间间隔


Quick Start
------------

这里介绍如何在基于Spring的项目中使用UidGenerator, 具体流程如下:<br/>

### 步骤1: 安装依赖
先下载[Java8](http://www.oracle.com/technetwork/java/javase/downloads/jdk8-downloads-2133151.html), [MySQL](https://dev.mysql.com/downloads/mysql/)和[Maven](https://maven.apache.org/download.cgi)

#### 设置环境变量
maven无须安装, 设置好MAVEN_HOME即可. 可像下述脚本这样设置JAVA_HOME和MAVEN_HOME, 如已设置请忽略.
```shell
export MAVEN_HOME=/xxx/xxx/software/maven/apache-maven-3.3.9
export PATH=$MAVEN_HOME/bin:$PATH
JAVA_HOME="/Library/Java/JavaVirtualMachines/jdk1.8.0_91.jdk/Contents/Home";
export JAVA_HOME;
```

### 步骤2: 创建表WORKER_NODE
运行sql脚本以导入表WORKER_NODE, 脚本如下:
```sql
DROP DATABASE IF EXISTS `xxxx`;
CREATE DATABASE `xxxx` ;
use `xxxx`;
DROP TABLE IF EXISTS WORKER_NODE;
CREATE TABLE WORKER_NODE
(
ID BIGINT NOT NULL AUTO_INCREMENT COMMENT 'auto increment id',
HOST_NAME VARCHAR(64) NOT NULL COMMENT 'host name',
TYPE INT NOT NULL COMMENT 'node type: ACTUAL or CONTAINER',
LAUNCH_DATE DATE NOT NULL COMMENT 'launch date',
MODIFIED TIMESTAMP NOT NULL COMMENT 'modified time',
CREATED TIMESTAMP NOT NULL COMMENT 'created time',
PRIMARY KEY(ID),
UNIQUE KEY (HOST_NAME)
)
 COMMENT='DB WorkerID Assigner for UID Generator',ENGINE = INNODB;
```

修改[mysql.properties](src/test/resources/uid/mysql.properties)配置中, jdbc.url, jdbc.username和jdbc.password, 确保库地址, 名称, 端口号, 用户名和密码正确.

### 步骤3: 修改Spring配置
提供了两种生成器: [DefaultUidGenerator](src/main/java/com/baidu/fsg/uid/impl/DefaultUidGenerator.java)、[CachedUidGenerator](src/main/java/com/baidu/fsg/uid/impl/CachedUidGenerator.java)。如对UID生成性能有要求, 请使用CachedUidGenerator<br/>
对应Spring配置分别为: [default-uid-spring.xml](src/test/resources/uid/default-uid-spring.xml)、[cached-uid-spring.xml](src/test/resources/uid/cached-uid-spring.xml)

#### DefaultUidGenerator配置
```xml
<!-- DefaultUidGenerator -->
<bean id="defaultUidGenerator" class="com.baidu.fsg.uid.impl.DefaultUidGenerator" lazy-init="false">
    <property name="workerIdAssigner" ref="disposableWorkerIdAssigner"/>

    <!-- Specified bits & epoch as your demand. No specified the default value will be used -->
    <property name="timeBits" value="32"/>
    <property name="workerBits" value="18"/>
    <property name="seqBits" value="13"/>
    <property name="epochStr" value="2020-01-01"/>
</bean>
 
<!-- 用完即弃的WorkerIdAssigner，依赖DB操作 -->
<bean id="disposableWorkerIdAssigner" class="com.baidu.fsg.uid.worker.DisposableWorkerIdAssigner" />

```

#### CachedUidGenerator配置
```xml
<!-- CachedUidGenerator -->
<bean id="cachedUidGenerator" class="com.baidu.fsg.uid.impl.CachedUidGenerator">
    <property name="workerIdAssigner" ref="disposableWorkerIdAssigner" />
 
    <!-- 以下为可选配置, 如未指定将采用默认值 -->
    <!-- Specified bits & epoch as your demand. No specified the default value will be used -->
    <property name="timeBits" value="32"/>
    <property name="workerBits" value="18"/>
    <property name="seqBits" value="13"/>
    <property name="epochStr" value="2020-01-01"/>
 
    <!-- RingBuffer size扩容参数, 可提高UID生成的吞吐量. -->
    <!-- 默认:3， 原bufferSize=8192, 扩容后bufferSize= 8192 << 3 = 65536 -->
    <property name="boostPower" value="3"></property>
 
    <!-- 指定何时向RingBuffer中填充UID, 取值为百分比(0, 100), 默认为50 -->
    <!-- 举例: bufferSize=1024, paddingFactor=50 -> threshold=1024 * 50 / 100 = 512. -->
    <!-- 当环上可用UID数量 < 512时, 将自动对RingBuffer进行填充补全 -->
    <property name="paddingFactor" value="50"></property>
 
    <!-- 另外一种RingBuffer填充时机, 在Schedule线程中, 周期性检查填充 -->
    <!-- 默认:不配置此项, 即不实用Schedule线程. 如需使用, 请指定Schedule线程时间间隔, 单位:秒 -->
    <property name="scheduleInterval" value="60"></property>
 
    <!-- 拒绝策略: 当环已满, 无法继续填充时 -->
    <!-- 默认无需指定, 将丢弃Put操作, 仅日志记录. 如有特殊需求, 请实现RejectedPutBufferHandler接口(支持Lambda表达式) -->
    <property name="rejectedPutBufferHandler" ref="XxxxYourPutRejectPolicy"></property>
 
    <!-- 拒绝策略: 当环已空, 无法继续获取时 -->
    <!-- 默认无需指定, 将记录日志, 并抛出UidGenerateException异常. 如有特殊需求, 请实现RejectedTakeBufferHandler接口(支持Lambda表达式) -->
    <property name="rejectedTakeBufferHandler" ref="XxxxYourTakeRejectPolicy"></property>
 
</bean>
 
<!-- 用完即弃的WorkerIdAssigner, 依赖DB操作 -->
<bean id="disposableWorkerIdAssigner" class="com.baidu.fsg.uid.worker.DisposableWorkerIdAssigner" />
 
```

#### Mybatis配置
[mybatis-spring.xml](src/test/resources/uid/mybatis-spring.xml)配置说明如下:

```xml
<!-- Spring annotation扫描 -->
<context:component-scan base-package="com.baidu.fsg.uid" />

<bean id="sqlSessionFactory" class="org.mybatis.spring.SqlSessionFactoryBean">
    <property name="dataSource" ref="dataSource" />
    <property name="mapperLocations" value="classpath:/META-INF/mybatis/mapper/M_WORKER*.xml" />
</bean>

<!-- 事务相关配置 -->
<tx:annotation-driven transaction-manager="transactionManager" order="1" />

<bean id="transactionManager" class="org.springframework.jdbc.datasource.DataSourceTransactionManager">
	<property name="dataSource" ref="dataSource" />
</bean>

<!-- Mybatis Mapper扫描 -->
<bean class="org.mybatis.spring.mapper.MapperScannerConfigurer">
	<property name="annotationClass" value="org.springframework.stereotype.Repository" />
	<property name="basePackage" value="com.baidu.fsg.uid.worker.dao" />
	<property name="sqlSessionFactoryBeanName" value="sqlSessionFactory" />
</bean>

<!-- 数据源配置 -->
<bean id="dataSource" parent="abstractDataSource">
	<property name="driverClassName" value="${mysql.driver}" />
	<property name="maxActive" value="${jdbc.maxActive}" />
	<property name="url" value="${jdbc.url}" />
	<property name="username" value="${jdbc.username}" />
	<property name="password" value="${jdbc.password}" />
</bean>

<bean id="abstractDataSource" class="com.alibaba.druid.pool.DruidDataSource" destroy-method="close">
	<property name="filters" value="${datasource.filters}" />
	<property name="defaultAutoCommit" value="${datasource.defaultAutoCommit}" />
	<property name="initialSize" value="${datasource.initialSize}" />
	<property name="minIdle" value="${datasource.minIdle}" />
	<property name="maxWait" value="${datasource.maxWait}" />
	<property name="testWhileIdle" value="${datasource.testWhileIdle}" />
	<property name="testOnBorrow" value="${datasource.testOnBorrow}" />
	<property name="testOnReturn" value="${datasource.testOnReturn}" />
	<property name="validationQuery" value="${datasource.validationQuery}" />
	<property name="timeBetweenEvictionRunsMillis" value="${datasource.timeBetweenEvictionRunsMillis}" />
	<property name="minEvictableIdleTimeMillis" value="${datasource.minEvictableIdleTimeMillis}" />
	<property name="logAbandoned" value="${datasource.logAbandoned}" />
	<property name="removeAbandoned" value="${datasource.removeAbandoned}" />
	<property name="removeAbandonedTimeout" value="${datasource.removeAbandonedTimeout}" />
</bean>

<bean id="batchSqlSession" class="org.mybatis.spring.SqlSessionTemplate">
	<constructor-arg index="0" ref="sqlSessionFactory" />
	<constructor-arg index="1" value="BATCH" />
</bean>
```

### 步骤4: 运行示例单测
运行单测[CachedUidGeneratorTest](src/test/java/com/baidu/fsg/uid/CachedUidGeneratorTest.java), 展示UID生成、解析等功能
```java
@Resource
private UidGenerator uidGenerator;

@Test
public void testSerialGenerate() {
    // Generate UID
    long uid = uidGenerator.getUID();

    // Parse UID into [Timestamp, WorkerId, Sequence]
    // {"UID":"180363646902239241","parsed":{    "timestamp":"2017-01-19 12:15:46",    "workerId":"4",    "sequence":"9"        }}
    System.out.println(uidGenerator.parseUID(uid));

}
```

### 关于UID比特分配的建议
对于并发数要求不高、期望长期使用的应用, 可增加```timeBits```位数, 减少```seqBits```位数. 例如节点采取用完即弃的WorkerIdAssigner策略, 重启频率为12次/天,
那么配置成```{"workerBits":23,"timeBits":31,"seqBits":9}```时, 可支持28个节点以整体并发量14400 UID/s的速度持续运行68年.

对于节点重启频率频繁、期望长期使用的应用, 可增加```workerBits```和```timeBits```位数, 减少```seqBits```位数. 例如节点采取用完即弃的WorkerIdAssigner策略, 重启频率为24*12次/天,
那么配置成```{"workerBits":27,"timeBits":30,"seqBits":6}```时, 可支持37个节点以整体并发量2400 UID/s的速度持续运行34年.