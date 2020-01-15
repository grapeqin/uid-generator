DROP TABLE IF EXISTS worker_node;
CREATE TABLE worker_node
(
  id          BIGINT      NOT NULL AUTO_INCREMENT COMMENT 'auto increment id',
  host_name   VARCHAR(64) NOT NULL COMMENT 'host name',
  type        INT         NOT NULL COMMENT 'node type: ACTUAL or CONTAINER',
  launch_date DATE        NOT NULL COMMENT 'launch date',
  modified    TIMESTAMP   NOT NULL COMMENT 'modified time',
  created     TIMESTAMP   NOT NULL COMMENT 'created time',
  PRIMARY KEY (id),
  UNIQUE KEY (host_name)
)
 COMMENT='DB WorkerID Assigner for UID Generator',ENGINE = INNODB;