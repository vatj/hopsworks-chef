DROP PROCEDURE IF EXISTS `path_resolver`;
DROP FUNCTION IF EXISTS `path_resolver_fn`;

DELIMITER //
CREATE PROCEDURE path_resolver(IN `parent_id` BIGINT, 
                               OUT `inode_path` VARCHAR(255))
BEGIN
  DECLARE next_parent_id BIGINT;
  DECLARE inode_name VARCHAR(255);
  DECLARE parent_path VARCHAR(255);

  IF `parent_id` = 1 THEN
    -- We are at the root of the file system
    SET `inode_path` =  "/";
  ELSE

    -- Not the root, we need to traverse more.
    -- Get the information about the current inode
    SELECT `h`.`parent_id`, `h`.`name`
    INTO next_parent_id, inode_name
    FROM `hops`.`hdfs_inodes` `h`
    WHERE `h`.`id` = `parent_id`;

    -- Recursively traverse upstream
    CALL path_resolver(next_parent_id, parent_path);

    -- Assemble the path
    SET `inode_path` = CONCAT(parent_path, inode_name, "/");
  END IF;
END //


-- MySQL does not support recursive functions. 
-- Wrap the procedure above into a function to make the rest of the migrations easier
CREATE FUNCTION path_resolver_fn(`parent_id` BIGINT, `name` VARCHAR(255))
RETURNS VARCHAR(255)
DETERMINISTIC
BEGIN
  DECLARE parent_path VARCHAR(255);

  CALL path_resolver(`parent_id`, parent_path);

  RETURN CONCAT(parent_path, `name`);
END //

DELIMITER ;

-- HWORKS-480: Remove inode foreign key from git repositories
ALTER TABLE `hopsworks`.`git_repositories` ADD COLUMN `name` VARCHAR(255) COLLATE latin1_general_cs NOT NULL;
ALTER TABLE `hopsworks`.`git_repositories` ADD COLUMN `path` VARCHAR(1000) COLLATE latin1_general_cs NOT NULL;

-- Migration
SET SQL_SAFE_UPDATES = 0;
UPDATE
    `hopsworks`.`git_repositories`
SET
    path = path_resolver_fn(`inode_pid`, `inode_name`);
SET SQL_SAFE_UPDATES = 1;

SET SQL_SAFE_UPDATES = 0;
UPDATE
    `hopsworks`.`git_repositories`
SET
    name = inode_name;
SET SQL_SAFE_UPDATES = 1;

ALTER TABLE `hopsworks`.`git_repositories` DROP FOREIGN KEY `repository_inode_fk`;
ALTER TABLE `hopsworks`.`git_repositories` DROP KEY `repository_inode_constraint_unique`;
ALTER TABLE `hopsworks`.`git_repositories`
DROP COLUMN `inode_pid`,
    DROP COLUMN `inode_name`,
    DROP COLUMN `partition_id`;

ALTER TABLE `hopsworks`.`git_repositories` ADD UNIQUE KEY `repository_path_constraint_unique` (`path`);

-- HWORKS-515: Remove inode foreign key from feature_store_code
ALTER TABLE `hopsworks`.`feature_store_code` DROP FOREIGN KEY `inode_fk_fsc`;
ALTER TABLE `hopsworks`.`feature_store_code` DROP KEY `inode_fk_fsc`;
ALTER TABLE `hopsworks`.`feature_store_code` DROP COLUMN `inode_pid`, DROP COLUMN `partition_id`;
ALTER TABLE `hopsworks`.`feature_store_code` RENAME COLUMN `inode_name` TO `name`;

ALTER TABLE `hopsworks`.`feature_store` ADD COLUMN `name` varchar(100) COLLATE latin1_general_cs NOT NULL;

SET SQL_SAFE_UPDATES = 0;
UPDATE `hopsworks`.`feature_store` `fs` 
  LEFT JOIN `project` `proj` ON `fs`.`project_id` = `proj`.`id`
SET `fs`.`name` = `proj`.`projectname`;
SET SQL_SAFE_UPDATES = 1;

-- HWORKS-486: Remove inode from project
ALTER TABLE `hopsworks`.`project` DROP FOREIGN KEY `FK_149_289`;
ALTER TABLE `hopsworks`.`project` DROP INDEX `inode_pid`;
ALTER TABLE `hopsworks`.`project` DROP COLUMN `inode_pid`;
ALTER TABLE `hopsworks`.`project` DROP COLUMN `inode_name`;
ALTER TABLE `hopsworks`.`project` DROP COLUMN `partition_id`;

-- HWORKS-526: Remove inode foreign key from validation_table
ALTER TABLE `hopsworks`.`validation_report` DROP FOREIGN KEY `inode_result_fk`;
ALTER TABLE `hopsworks`.`validation_report` DROP KEY `inode_result_fk`;
ALTER TABLE `hopsworks`.`validation_report` DROP COLUMN `inode_pid`, DROP COLUMN `partition_id`;

ALTER TABLE `hopsworks`.`validation_report` RENAME COLUMN `inode_name` TO `file_name`;

-- HWORKS-523: Remove inode foreign key from transformation_function
ALTER TABLE `hopsworks`.`transformation_function` DROP FOREIGN KEY `inode_fn_fk`;
ALTER TABLE `hopsworks`.`transformation_function` DROP KEY `inode_fn_fk`;

ALTER TABLE `hopsworks`.`transformation_function` DROP COLUMN `inode_pid`, DROP COLUMN `partition_id`, DROP COLUMN `inode_name`;

-- FSTORE-737: Remove inode foreign key from feature_group_commit
ALTER TABLE `hopsworks`.`feature_group_commit` DROP FOREIGN KEY `hopsfs_parquet_inode_fk`;
ALTER TABLE `hopsworks`.`feature_group_commit` DROP KEY `hopsfs_parquet_inode_fk`;
ALTER TABLE `hopsworks`.`feature_group_commit`
  DROP COLUMN `inode_pid`,
  DROP COLUMN `inode_name`,
  DROP COLUMN `partition_id`;

ALTER TABLE `hopsworks`.`feature_group_commit` ADD COLUMN `archived` TINYINT(1) NOT NULL DEFAULT '0';

-- FSTORE-849: Add Spline dataframe functionality
ALTER TABLE `hopsworks`.`on_demand_feature_group` 
  ADD COLUMN `spine` TINYINT(1) NOT NULL DEFAULT 0,
  MODIFY COLUMN `connector_id` INT(11) NULL;

-- HWORKS-487: Remove inode from dataset
ALTER TABLE `hopsworks`.`dataset` DROP FOREIGN KEY `FK_149_435`;
ALTER TABLE `hopsworks`.`dataset` DROP INDEX `inode_id`;
ALTER TABLE `hopsworks`.`dataset` DROP INDEX `inode_pid`;
ALTER TABLE `hopsworks`.`dataset` DROP INDEX `uq_dataset`;
ALTER TABLE `hopsworks`.`dataset` DROP COLUMN `inode_pid`;
ALTER TABLE `hopsworks`.`dataset` DROP COLUMN `inode_id`;
ALTER TABLE `hopsworks`.`dataset` DROP COLUMN `partition_id`;
ALTER TABLE `hopsworks`.`dataset` ADD KEY `dataset_name` (`inode_name`);

-- HWORKS-574: Remove inode from hdfs_command_execution
ALTER TABLE `hopsworks`.`hdfs_command_execution` DROP FOREIGN KEY `fk_hdfs_file_command_2`;
ALTER TABLE `hopsworks`.`hdfs_command_execution` DROP INDEX `fk_hdfs_file_command_2_idx`;
ALTER TABLE `hopsworks`.`hdfs_command_execution` DROP INDEX `uq_src_inode`;
ALTER TABLE `hopsworks`.`hdfs_command_execution` DROP COLUMN `src_inode_pid`;
ALTER TABLE `hopsworks`.`hdfs_command_execution` DROP COLUMN `src_inode_name`;
ALTER TABLE `hopsworks`.`hdfs_command_execution` DROP COLUMN `src_inode_partition_id`;
ALTER TABLE `hopsworks`.`hdfs_command_execution` ADD COLUMN `src_path` VARCHAR(1000) COLLATE latin1_general_cs NOT NULL;
ALTER TABLE `hopsworks`.`hdfs_command_execution` ADD UNIQUE KEY `uq_src_path` (`src_path`);
-- FSTORE-577
ALTER TABLE `hopsworks`.`feature_store_s3_connector` ADD COLUMN `arguments` VARCHAR(2000) DEFAULT NULL;

-- HWORKS-588: Remove inode foreign key from external feature group
ALTER TABLE `hopsworks`.`on_demand_feature_group` DROP FOREIGN KEY `on_demand_inode_fk`;
ALTER TABLE `hopsworks`.`on_demand_feature_group` DROP KEY `on_demand_inode_fk`;
ALTER TABLE `hopsworks`.`on_demand_feature_group`
  DROP COLUMN `inode_pid`,
  DROP COLUMN `inode_name`,
  DROP COLUMN `partition_id`;

-- HWORKS-587: Remove inode foreign key from feature views
ALTER TABLE `hopsworks`.`feature_view` DROP FOREIGN KEY `fv_inode_fk`;
ALTER TABLE `hopsworks`.`feature_view` DROP KEY `fv_inode_fk`;
ALTER TABLE `hopsworks`.`feature_view`
  DROP COLUMN `inode_pid`,
  DROP COLUMN `inode_name`,
  DROP COLUMN `partition_id`;

ALTER TABLE `cached_feature_extra_constraints` ADD KEY stream_feature_group_fk (`stream_feature_group_id`);
ALTER TABLE `cached_feature_extra_constraints` ADD CONSTRAINT `stream_feature_group_fk1` FOREIGN KEY (`stream_feature_group_id`) REFERENCES `stream_feature_group` (`id`) ON DELETE CASCADE ON UPDATE NO ACTION;

ALTER TABLE `hopsworks`.`git_executions` ADD COLUMN `hostname` VARCHAR(128) COLLATE latin1_general_cs NOT NULL DEFAULT "localhost";