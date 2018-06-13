/*
  NOTES:
   - the script assumes IMCK's database is named "bhima".  Please rename the IMCK
   database to "bhima" if it is not called that already.

  TO RUN:
    1. Create a clean database by running ./sh/build-init-database.sh or yarn build:clean.
    2. Log into mysql's command line:  mysql $DB_NAME
    3. Run the script: source server/models/migrations/Tshikaji/migrate.sql

  Importing posting_journal
  -------------------------
  Here are posting_journal dependencies :
  1. currency
  2. country
  3. province
  4. sector
  6. village
  7. enterprise
  8. fiscal_year
  9. project
  10. transaction_type
  11. user
  12. cost center
  13. profit center
  14. period
  15. account_type
  16. reference
  17. account
  18. posting_journal
*/

-- optimisations for bulk data import
-- see https://dev.mysql.com/doc/refman/5.7/en/optimizing-innodb-bulk-data-loading.html
SET autocommit=0;
SET foreign_key_checks=0;
SET unique_checks=0;

/*!40101 SET NAMES utf8 */;
/*!40101 SET character_set_client = utf8 */;

/*
Useful Functions/ Procedures
*/

DELIMITER $$

CREATE PROCEDURE MergeSector(
  IN beforeUuid CHAR(36),
  IN afterUuid CHAR(36)
) BEGIN
  DECLARE `isDuplicate` BOOL DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET `isDuplicate` = 1;
  UPDATE village SET sector_uuid = HUID(afterUuid) WHERE sector_uuid = HUID(beforeUuid);
  DELETE FROM sector WHERE sector.uuid = HUID(beforeUuid);
END $$

CREATE PROCEDURE ComputePeriodZero(
  IN year INT
) BEGIN
  DECLARE fyId INT;
  DECLARE previousFyId INT;
  DECLARE enterpriseId INT;
  DECLARE periodZeroId INT;

  SELECT id, previous_fiscal_year_id, enterprise_id
    INTO fyId, previousFyId, enterpriseId
  FROM fiscal_year WHERE YEAR(start_date) = year;

  SET periodZeroId = CONCAT(year, 0);

  -- UPDATE period SET start_date = DATE(CONCAT(year, '-01-01')) AND end_date = DATE(CONCAT(year, '-01-01'));

  INSERT INTO period_total (enterprise_id, fiscal_year_id, period_id, account_id, credit, debit, locked)
    SELECT enterpriseId, fyId, periodZeroId, account_id, SUM(credit), SUM(debit), 0
    FROM period_total
    WHERE fiscal_year_id = previousFyId
    GROUP BY account_id;
END $$


-- NOTE: this uses 2.x's tables, not 1.x's
CREATE PROCEDURE VouchersFromTransactionTypeGL(
  IN transactionTypeId INT
) BEGIN
  CREATE TEMPORARY TABLE transactions AS
    SELECT * FROM general_ledger WHERE transaction_type_id = transactionTypeId;

  CREATE TEMPORARY TABLE mapping AS
    SELECT DISTINCT trans_id, HUID(UUID()) record_uuid FROM general_ledger WHERE transaction_type_id = transactionTypeId;

  CREATE TEMPORARY TABLE stage_voucher AS
    SELECT m.record_uuid, MAX(trans_date) date, MAX(project_id) project_id, NULL AS reference, MAX(currency_id) currency_id,
      SUM(debit) amount, MAX(description) description, MAX(user_id) user_id, MAX(trans_date) created_at, transactionTypeId AS type_id
      FROM transactions t JOIN mapping m ON t.trans_id = m.trans_id
      GROUP BY t.trans_id;

  INSERT INTO voucher (`uuid`, `date`, project_id, reference, currency_id, amount, description, user_id, created_at, type_id)
    SELECT record_uuid, date, project_id, reference, currency_id, amount, description, user_id, created_at, type_id
    FROM stage_voucher;


  INSERT INTO voucher_item (`uuid`, account_id, debit, credit, voucher_uuid, document_uuid, entity_uuid)
    SELECT HUID(UUID()), account_id, debit, credit, m.record_uuid, reference_uuid, entity_uuid
    FROM transactions t JOIN mapping m ON t.trans_id = m.trans_id;

  UPDATE general_ledger gl JOIN mapping m ON gl.trans_id = m.trans_id SET gl.record_uuid = m.record_uuid WHERE transaction_type_id = transactionTypeId;

  DROP TABLE transactions;
  DROP TABLE mapping;
  DROP TABLE stage_voucher;
END $$

CREATE PROCEDURE VouchersFromTransactionTypePJ(
  IN transactionTypeId INT
) BEGIN
  CREATE TEMPORARY TABLE transactions AS
    SELECT * FROM posting_journal WHERE transaction_type_id = transactionTypeId;

  CREATE TEMPORARY TABLE mapping AS
    SELECT DISTINCT trans_id, HUID(UUID()) record_uuid FROM posting_journal WHERE transaction_type_id = transactionTypeId;

  CREATE TEMPORARY TABLE stage_voucher AS
    SELECT m.record_uuid, MAX(trans_date) date, MAX(project_id) project_id, NULL AS reference, MAX(currency_id) currency_id,
      SUM(debit) amount, MAX(description) description, MAX(user_id) user_id, MAX(trans_date) created_at, transactionTypeId AS type_id
      FROM transactions t JOIN mapping m ON t.trans_id = m.trans_id
      GROUP BY t.trans_id;

  INSERT INTO voucher (`uuid`, `date`, project_id, reference, currency_id, amount, description, user_id, created_at, type_id)
    SELECT record_uuid, date, project_id, reference, currency_id, amount, description, user_id, created_at, type_id
    FROM stage_voucher;


  INSERT INTO voucher_item (`uuid`, account_id, debit, credit, voucher_uuid, document_uuid, entity_uuid)
    SELECT HUID(UUID()), account_id, debit, credit, m.record_uuid, reference_uuid, entity_uuid
    FROM transactions t JOIN mapping m ON t.trans_id = m.trans_id;

  UPDATE posting_journal gl JOIN mapping m ON gl.trans_id = m.trans_id SET gl.record_uuid = m.record_uuid WHERE transaction_type_id = transactionTypeId;

  DROP TABLE transactions;
  DROP TABLE mapping;
  DROP TABLE stage_voucher;
END $$

DELIMITER ;

/* ALTER TABLE bhima.posting_journal ADD INDEX `inv_po_id` (`inv_po_id`); */
/* ALTER TABLE bhima.general_ledger ADD INDEX `inv_po_id` (`inv_po_id`); */

/* CURRENCY */

/*
  WRONG NAME : min_monentary_unit instead of min_monentary_unit
*/
DELETE FROM currency;
INSERT INTO currency (id, name, format_key, symbol, note, min_monentary_unit)
  SELECT id, name, format_key, symbol, note, min_monentary_unit FROM bhima.currency;

/* COUNTRY */
INSERT INTO country (`uuid`, name)
  SELECT HUID(`uuid`), country_fr FROM bhima.country;

/*
Migrate provinces.  We have two duplicates - Bandundu and Kasai Oriental
provinces.  We will remove them in a migration temporary table.

We save one of the uuids (the one not removed) to update the sector pointers later.
*/

CREATE TEMPORARY TABLE migrate_province AS
  SELECT * FROM bhima.province;

SET @KO_UUID_OLD = '525ecb4f-ae8d-40e1-9f86-913c5fe9b5a7';
SET @KO_UUID_NEW = '5891deb5-e725-48b2-a720-cbfcb95da36b'; -- the 2nd Kasai key

SET @BA_UUID_OLD = '2feea5a1-b738-45de-95b6-947e35e11f79';
SET @BA_UUID_NEW = '47927e29-2da0-4566-b6e5-a74a9670c4c5'; -- the 2nd Bandundu key

DELETE FROM migrate_province WHERE uuid in (@KO_UUID_OLD, @BA_UUID_OLD);

/* PROVINCE */
-- NOTE: Bandundu and Kasai Oriental are duplicated.  These are removed later.
INSERT INTO province (`uuid`, name, country_uuid)
  SELECT HUID(`uuid`), name, HUID(country_uuid) FROM migrate_province;

DROP TABLE migrate_province;

/* SECTOR */
CREATE TEMPORARY TABLE migrate_sector AS
  SELECT * FROM bhima.sector;

UPDATE migrate_sector SET province_uuid = @KO_UUID_NEW WHERE province_uuid = @KO_UUID_OLD;
UPDATE migrate_sector SET province_uuid = @BA_UUID_NEW WHERE province_uuid = @BA_UUID_OLD;

INSERT INTO sector (`uuid`, name, province_uuid)
  SELECT HUID(`uuid`), name, HUID(province_uuid) FROM migrate_sector;

/*
FIXME(@jniles) - Villages have way to many duplicates.  We can fix this later.
*/
ALTER TABLE village DROP KEY `village_1`;
INSERT INTO village (`uuid`, name, sector_uuid)
  SELECT HUID(`uuid`), name, HUID(sector_uuid) FROM bhima.village;

/*
Merge duplicate sectors

All these sectors have the same name, but are registered in both KO and Bas Congo.
Here, I delete the Bas Congo ones and keep the KO ones.
*/
CALL MergeSector('61414179-25e1-494a-895b-90d44138491c', '87055ace-2f6f-4a8f-9c07-1743079f01e9');
CALL MergeSector('449f5802-f33c-4455-b90a-aedb993e3c63', 'f9608a66-b425-4e90-878d-458174e392e1');
CALL MergeSector('6912ae18-c57f-444b-a3f1-47cf539d2b16', '9ab1a069-be59-419a-842c-2a3ad8c71e0d');
CALL MergeSector('4c9d1f3d-d5af-47ca-80fd-357c2f1fa807', '9cf5a7f2-4199-4a87-905b-709c7a0df73f');
CALL MergeSector('a3b5109b-3b9e-439e-8af0-732ecdc5d904', 'dd248048-b687-4fb6-a97c-81e73f95cb49');
CALL MergeSector('00712a73-694f-463e-b111-995871395bc1', '7d2740c1-aac9-40dc-8469-b1f74916afee');
CALL MergeSector('c43d8e55-7a42-4fee-9378-a830c0f42b43', 'd96f7e9a-1917-493b-bce7-c55b601e98aa');
CALL MergeSector('5d7ccadc-ddf6-41eb-93f7-a505e3280558', 'e2016756-76be-4ac9-a842-e39db81f251c');
CALL MergeSector('0404e9ea-ebd6-4f20-b1f8-6dc9f9313450', '32fac9d5-843a-4503-b142-21a3396c6f50');

/*
We should also merge locations, but only once the entire database is built.
*/

/* ENTERPRISE  */
SET @gainAccountId = 3378;
SET @lossAccountId = 3229;
INSERT INTO enterprise (id, name, abbr, phone, email, location_id, logo, currency_id, po_box, gain_account_id, loss_account_id)
  SELECT id, name, abbr, phone, email, HUID(location_id), logo, currency_id, po_box, @gainAccountId, @lossAccountId FROM bhima.enterprise;

SET @enterpriseId = (SELECT id FROM bhima.enterprise LIMIT 1);
INSERT INTO enterprise_setting (enterprise_id) VALUES  (@enterpriseId);

/* PROJECT */
INSERT INTO project (id, name, abbr, enterprise_id, zs_id, locked)
  SELECT id, name, abbr, enterprise_id, zs_id, 0 FROM bhima.project;

/* USER */
CREATE TEMPORARY TABLE user_migration AS SELECT * FROM bhima.user;

-- this user hasn't logged in since January.  I hope this is okay.
UPDATE user_migration SET username = 'jean_ndolo' where id = 22;

INSERT INTO `user` (id, username, password, display_name, email, active, deactivated, pin, last_login)
  SELECT id, username, password, CONCAT(first, ' ', last), email, active, 0, pin, IF(TIMESTAMP(last_login), TIMESTAMP(last_login), NOW()) FROM user_migration;

/*
  CREATE THE SUPERUSER for attributing permissions
*/
SET @SUPERUSER_ID = 1000;
SET @JOHN_DOE = 1001;
INSERT INTO `user` (id, username, password, display_name, email, active, deactivated, pin) VALUE
  (@SUPERUSER_ID, 'superuser', PASSWORD('superuser'), 'The Admin User', 'support@bhi.ma', 1, 0, 1000),
  (@JOHN_DOE, 'johndoe', PASSWORD('superuser'), 'An Unknown User (John Doe)', 'support@bhi.ma', 1, 0, 1000);

INSERT INTO `permission` (unit_id, user_id)
  SELECT id, @SUPERUSER_ID FROM unit;

INSERT INTO `project_permission` (project_id, user_id)
  SELECT id, @SUPERUSER_ID FROM project;

SET @roleUuid = HUID('7b7dd0d6-9273-4955-a703-126fbd504b61');

/* project role */
/*
  FOR EACH PROJECT DO WE NEED A NEW ROLE ???
  NEED TO BE FIXED
*/
INSERT INTO `role` (`uuid`, label, project_id)
  SELECT @roleUuid, 'Superuser', id FROM project LIMIT 1;

/* unit role */
INSERT INTO role_unit
  SELECT HUID(uuid()) as uuid, @roleUuid, id FROM unit;

/* action role */
INSERT INTO role_actions
  SELECT HUID(uuid()) as uuid, @roleUuid, id FROM actions;

/* user role */
INSERT INTO `user_role`(`uuid`, user_id, role_uuid)
  VALUES(HUID(uuid()), @SUPERUSER_ID, @roleUuid);

-- migrate exchange rate
INSERT INTO exchange_rate (id, enterprise_id, currency_id, rate, `date`)
  SELECT id, @enterpriseId, foreign_currency_id, rate, IF(`date` = 0, NOW(), `date`) FROM bhima.exchange_rate;

-- delete future exchange rates
DELETE FROM exchange_rate WHERE DATE(`date`) > DATE(NOW());

/* FISCAL YEAR */
/*
  WARNING: USE OF bhima_test HERE, PLEASE USE THE NAME OF NEW DATABASE USED
  FOR GETTING THE OLD ID
*/
-- remove duplicate FYs
DELETE FROM bhima.period WHERE fiscal_year_id IN (6, 7);
DELETE FROM bhima.fiscal_year WHERE id IN (6, 7);

INSERT INTO fiscal_year (enterprise_id, id, number_of_months, label, start_date, end_date, previous_fiscal_year_id, locked, created_at, updated_at, user_id, note)
  SELECT enterprise_id, id, number_of_months, fiscal_year_txt, MAKEDATE(start_year, 1), DATE_ADD(DATE_ADD(MAKEDATE(start_year, 1), INTERVAL (12)-1 MONTH), INTERVAL (31)-1 DAY), previous_fiscal_year, 0, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), 1, start_year
  FROM bhima.fiscal_year;

/* TRANSACTION TYPE */
/*
 NOTE: Transaction Types were completely re-written in 2.x and certain transaction
types are hard-coded "fixed" types.  These need to be handled manually.

NOTE: These are the distributions of data in the transct3
*/
DELETE FROM transaction_type;
INSERT INTO transaction_type (id, `text`, type, fixed)
  SELECT id, service_txt, service_txt, 1 FROM bhima.transaction_type;

/* COST CENTER */
INSERT INTO cost_center (project_id, id, `text`, note, is_principal)
  SELECT project_id, id, `text`, note, is_principal FROM bhima.cost_center;

/* PROFIT CENTER */
INSERT INTO profit_center (project_id, id, `text`, note)
  SELECT project_id, id, `text`, note FROM bhima.profit_center;

/*
Migrate period information.  Since we have foreign keys off, the easiest way is
to delete the default data created by init database and then smash in IMCK's data.
*/
INSERT INTO period (id, fiscal_year_id, `number`, start_date, end_date, locked)
  SELECT id, fiscal_year_id, period_number, IF(period_start=0, NULL, period_start), IF(period_stop=0, NULL, period_stop), locked
    FROM bhima.period;

-- these will be computed later
DELETE FROM period WHERE number = 0;

-- insert period 0 for all fiscal years.
INSERT INTO period (id, fiscal_year_id, `number`, start_date, end_date)
  SELECT CONCAT(start_year, 0), id, 0, NULL, NULL FROM bhima.fiscal_year;


/*
  NOTE(@jniles) - I don't think we need to migrate account types.  They are already
  built in the initial database engine. We just need to update the 1.x account
  type links to point to the correct account types.
*/

/* REFERENCE */
INSERT INTO reference (id, is_report, ref, `text`, `position`, `reference_group_id`, `section_resultat_id`)
  SELECT id, is_report, ref, `text`, `position`, `reference_group_id`, `section_resultat_id` FROM bhima.reference;

/*
Migrating accounts is kind of tricky.  We need to fit the 2.x model of accounts
and account types.  This means eliminating duplicate accounts and migrating
account types based on account class.

First we eliminate duplicates from the accounts.  We do this by appending random
text to the label and prepending 9 to the account number.
*/
CREATE TEMPORARY TABLE account_migration AS SELECT * FROM bhima.account;

-- hard to remove accounts, never used.
DELETE FROM account_migration WHERE id IN (3967, 3968, 3944);

CREATE TEMPORARY TABLE account_number_dupes AS
  SELECT MIN(id) AS id FROM account_migration GROUP BY account_number HAVING COUNT(account_number) > 1;

-- prepend "9" to account number to make them unique
UPDATE account_migration SET account_number = CONCAT('9', account_number) WHERE id IN (SELECT id FROM account_number_dupes);

-- SELECT account_number from account GROUP BY account_number HAVING COUNT(account_number) = 2;
INSERT INTO account (id, type_id, enterprise_id, `number`, label, parent, locked, hidden, cc_id, pc_id, created, classe, reference_id)
  SELECT id, account_type_id, enterprise_id, account_number, account_txt, parent, locked, IF(is_ohada, 0, 1), cc_id, pc_id, created, classe, reference_id
  FROM account_migration;

DROP TABLE account_migration;

/*
First, we treat the title accounts.  These are any accounts with children, and
all accounts with the previous title type.

Then we do income/expense.  These are any accounts that are not title accounts
and are in the appropriate class.

Finally, assets/liabilities are pretty brutally forced in.
*/
SET @asset = 1;
SET @liability = 2;
SET @equity = 3;
SET @income = 4;
SET @expense = 5;
SET @title = 6;

-- setting up accounts for processing
CREATE TEMPORARY TABLE title_accounts AS (SELECT DISTINCT parent AS id FROM account);

-- title accounts
UPDATE account SET type_id = @title WHERE id IN (SELECT id FROM title_accounts);

-- income accounts
UPDATE account SET type_id = @income WHERE id NOT IN (SELECT id FROM title_accounts) AND LEFT(number, 1) = '7';

-- expense accounts
UPDATE account SET type_id = @expense WHERE id NOT IN (SELECT id FROM title_accounts) AND LEFT(number, 1) = '6';

-- liability accounts
UPDATE account SET type_id = @liability WHERE id NOT IN (SELECT id FROM title_accounts) AND LEFT(number, 1) = '4';

-- asset accounts
UPDATE account SET type_id = @asset WHERE id NOT IN (SELECT id FROM title_accounts) AND LEFT(number, 1) IN ('1', '2', '3', '5', '8');

DROP TABLE title_accounts;

CREATE TEMPORARY TABLE `inventory_group_dupes` AS
  SELECT COUNT(code) as N, code FROM bhima.inventory_group GROUP BY code HAVING COUNT(code) > 1;

/* INVENTORY GROUP */
INSERT INTO inventory_group (`uuid`, name, code, sales_account, cogs_account, stock_account, donation_account, expires, unique_item)
  SELECT HUID(`uuid`), name, code, sales_account, cogs_account, stock_account, donation_account, 1, 0
  FROM bhima.inventory_group
  WHERE code NOT IN (SELECT code from inventory_group_dupes);

INSERT INTO inventory_group (`uuid`, name, code, sales_account, cogs_account, stock_account, donation_account, expires, unique_item)
  SELECT HUID(`uuid`), name, CONCAT(code, FLOOR(RAND() * 10000)) , sales_account, cogs_account, stock_account, donation_account, 1, 0
  FROM bhima.inventory_group
  WHERE code IN (SELECT code from inventory_group_dupes);

/* INVENTORY UNIT */
DELETE FROM inventory_unit;
INSERT INTO inventory_unit (id, abbr, `text`)
  SELECT id, `text`, `text` FROM bhima.inventory_unit;

/* INVENTORY TYPE */
DELETE FROM inventory_type;
INSERT INTO inventory_type (id, `text`)
  SELECT id, `text` FROM bhima.inventory_type;

/*
Unfortunately, the IMCK database does not have unique inventory item labels, so
we have to make them unique.  The following code first imports all inventory
that have unique labels and then makes the others unique by appending their code
to the description.
*/

CREATE TEMPORARY TABLE `inventory_dupes` AS
  SELECT COUNT(text) as N, text FROM bhima.inventory GROUP BY text HAVING COUNT(text) > 1;

/* INVENTORY */
INSERT INTO inventory (enterprise_id, `uuid`, code, `text`, price, default_quantity, group_uuid, unit_id, unit_weight, unit_volume, stock, stock_max, stock_min, type_id, consumable, sellable, note, locked, delay, avg_consumption, purchase_interval, num_purchase, num_delivery, created_at, updated_at)
SELECT enterprise_id, HUID(`uuid`), code, `text`, price, 1, HUID(group_uuid), unit_id, unit_weight, unit_volume, stock, stock_max, stock_min, type_id, consumable, 1, `text`, 0, 1, 1, 1, 0, 0, origin_stamp, origin_stamp
  FROM bhima.inventory WHERE text NOT IN (SELECT text FROM `inventory_dupes`);

INSERT INTO inventory (enterprise_id, `uuid`, code, `text`, price, default_quantity, group_uuid, unit_id, unit_weight, unit_volume, stock, stock_max, stock_min, type_id, consumable, sellable, note, locked, delay, avg_consumption, purchase_interval, num_purchase, num_delivery, created_at, updated_at)
  SELECT enterprise_id, HUID(`uuid`), code, CONCAT(`text`, ' (', code, ')'), price, 1, HUID(group_uuid), unit_id, unit_weight, unit_volume, stock, stock_max, stock_min, type_id, consumable, 1, `text`, 0, 1, 1, 1, 0, 0, origin_stamp, origin_stamp
    FROM bhima.inventory WHERE text IN (SELECT text from `inventory_dupes`);

DROP TABLE inventory_dupes;

/* PRICE LIST */
INSERT INTO price_list (`uuid`, enterprise_id, label, description, created_at, updated_at)
  SELECT HUID(`uuid`), enterprise_id, title, description, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
  FROM bhima.price_list;

/*
  NOTE(@jniles) - IMCK used a hard-coded inventory item as the price list for the 5% charge
  for delai. This is now "Invoicing Fee".  But, we will need to build the "convention" price
  list of 100% of their current prices for every single item.
*/
SET @conventionPriceList = HUID('fbcedd3e-9b6c-4cb3-aa46-7c6b04df32d9');
INSERT INTO price_list_item (`uuid`, `inventory_uuid`, `price_list_uuid`, `label`, `value`, `is_percentage`)
 SELECT HUID(UUID()), inventory.uuid, @conventionPriceList, 'Liste pour les Conventions', 100, 1 FROM inventory;

/* DEBTOR GROUP */
INSERT INTO debtor_group (enterprise_id, `uuid`, name, account_id, location_id, phone, email, note, locked, max_credit, is_convention, price_list_uuid, apply_discounts, apply_invoicing_fees, apply_subsidies, created_at, updated_at)
  SELECT enterprise_id, HUID(`uuid`), name, account_id, HUID(location_id), phone, email, note, locked, max_credit, is_convention, HUID(price_list_uuid), 1, 1, 1, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
  FROM bhima.debitor_group;

/* DEBTOR */
/*
  THERE IS DEBTOR WHO BELONGS TO A GROUP WHICH DOESN'T HAVE AN EXISTING ACCOUNT ID
*/
INSERT INTO debtor (`uuid`, group_uuid, `text`)
  SELECT HUID(`uuid`), HUID(group_uuid), SUBSTRING(REPLACE(REPLACE(`text`, 'Debtor', 'D'), 'undefined', ''), 1, 100)
  FROM bhima.debitor;

/* CREDITOR GROUP */
INSERT INTO creditor_group (enterprise_id, `uuid`, name, account_id, locked)
  SELECT enterprise_id, HUID(`uuid`), name, account_id, locked FROM bhima.creditor_group;

/* CREDITOR */
INSERT INTO creditor (`uuid`, group_uuid, `text`)
  SELECT HUID(`uuid`), HUID(group_uuid), SUBSTRING(`text`, 1, 100) FROM bhima.creditor;

/* SERVICE */
INSERT INTO service (id, `uuid`, enterprise_id, name, cost_center_id, profit_center_id)
  SELECT id, HUID(UUID()), 200, name, cost_center_id, profit_center_id FROM bhima.service;


/* INVOICE */
/*
  THERE ARE SALE (58) MADE BY USER (SELLER_ID) WHO DOESN'T EXIST IN THE USER TABLE
  select count(*) from sale where sale.seller_id not in (select id from `user`);
*/

CREATE TEMPORARY TABLE sale_migration AS SELECT * FROM bhima.sale;
ALTER TABLE sale_migration ADD INDEX `uuid` (`uuid`);

/*

sale --> invoice

The following code deals with invoices and invoice links to the posting journal.
In 1.x, we used inv_po_id to link the `posting_journal` to the `sale` table.
*/
SET @saleTransactionType = 2;

CREATE TEMPORARY TABLE `sale_record_map` AS
  SELECT HUID(MAX(s.uuid)) AS uuid, p.trans_id FROM sale_migration s JOIN bhima.posting_journal p ON s.uuid = p.inv_po_id
  WHERE p.origin_id = @saleTransactionType
  GROUP BY trans_id;

INSERT INTO `sale_record_map`
  SELECT HUID(MAX(s.uuid)) AS uuid, g.trans_id FROM sale_migration s JOIN bhima.general_ledger g ON s.uuid = g.inv_po_id
  WHERE g.origin_id = @saleTransactionType
  GROUP BY trans_id;

/* INDEX FOR SALE RECORD MAP */
ALTER TABLE sale_record_map ADD INDEX `uuid` (`uuid`);

-- we have duplicate references to clean up
CREATE TEMPORARY TABLE sale_reference_dupes AS
  SELECT project_id, reference, MIN(uuid) AS uuid, 0 AS 'n' FROM sale_migration GROUP BY project_id, reference HAVING COUNT(reference) > 1;

SET @s = (SELECT max(reference) FROM sale_migration);
UPDATE sale_reference_dupes SET n = (@s := @s + 1);

UPDATE sale_migration sm JOIN sale_reference_dupes sd ON sm.uuid = sd.uuid SET sm.reference = sd.n;

/*!40000 ALTER TABLE `invoice` DISABLE KEYS */;
INSERT INTO invoice (project_id, reference, `uuid`, cost, debtor_uuid, service_id, user_id, `date`, description)
  SELECT project_id, reference, HUID(`uuid`), cost, HUID(debitor_uuid), service_id, IF(seller_id = 0, @JOHN_DOE, seller_id), invoice_date, note
  FROM sale_migration;
/*!40000 ALTER TABLE `invoice` ENABLE KEYS */;

CREATE TEMPORARY TABLE reversed_invoices AS SELECT HUID(sale_uuid) AS `uuid` FROM bhima.credit_note;
ALTER TABLE reversed_invoices ADD INDEX `uuid` (`uuid`);
UPDATE invoice SET reversed = 1 WHERE invoice.uuid IN (SELECT uuid FROM reversed_invoices);

/* INVOICE ITEM */
/*
  SELECT JUST invoice_item for invoice who exist
  THIS QUERY TAKE TOO LONG TIME
*/

CREATE TEMPORARY TABLE temp_sale_item AS
  SELECT HUID(sale_uuid) AS sale_uuid, HUID(sale_item.uuid) AS `uuid`, HUID(inventory_uuid) AS inventory_uuid, quantity, inventory_price, transaction_price, debit, credit
FROM bhima.sale_item;

/* remove the unique key for boosting the insert operation */
/*!40000 ALTER TABLE `invoice_item` DISABLE KEYS */;

-- FIXME(@jniles) - this works for the import, but on the long run we should migrate their old frais inventory items.
ALTER TABLE invoice_item DROP KEY `invoice_item_1`;
INSERT INTO invoice_item (invoice_uuid, `uuid`, inventory_uuid, quantity, inventory_price, transaction_price, debit, credit)
  SELECT sale_uuid, `uuid`, inventory_uuid, quantity, inventory_price, transaction_price, debit, credit FROM temp_sale_item;
/*!40000 ALTER TABLE `invoice_item` ENABLE KEYS */;

/* POSTING JOURNAL*/
/*
  NOTE: CONVERT DOC_NUM TO RECORD_UUID
*/
INSERT INTO posting_journal (uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date, record_uuid, description, account_id, debit, credit, debit_equiv, credit_equiv, currency_id, entity_uuid, reference_uuid, comment, transaction_type_id, user_id, cc_id, pc_id, created_at, updated_at)
  SELECT HUID(uuid), project_id, fiscal_year_id, period_id, trans_id, TIMESTAMP(trans_date), HUID(UUID()), description, account_id, debit, credit, debit_equiv, credit_equiv, currency_id, IF(LENGTH(deb_cred_uuid) = 36, HUID(deb_cred_uuid), NULL), NULL, comment, origin_id, user_id, cc_id, pc_id, TIMESTAMP(trans_date), CURRENT_TIMESTAMP()
  FROM bhima.posting_journal;

-- TODO - deal with this in a better way
-- account for data corruption (modifies HBB's dataset!)
UPDATE bhima.general_ledger SET deb_cred_uuid = NULL WHERE LEFT(deb_cred_uuid, 1) = '"';

/* GENERAL LEDGER */
/*
  HBB4229 HAS AS INV_PO_ID PCE29850 WHICH CANNOT BE CONVERTED BY HUID
  SO WE CONVERT PCE29850 TO 36 CHARS BEFORE PASSING IT TO HUID
  WE WILL USE 8d344ed2-5db0-11e8-8061-54e1ad7439c7 AS UUID
*/
INSERT INTO general_ledger (uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date, record_uuid, description, account_id, debit, credit, debit_equiv, credit_equiv, currency_id, entity_uuid, reference_uuid, comment, transaction_type_id, user_id, cc_id, pc_id, created_at, updated_at)
  SELECT HUID(`uuid`), project_id, fiscal_year_id, period_id, trans_id, TIMESTAMP(trans_date), HUID(UUID()), description, account_id, debit, credit, debit_equiv, credit_equiv, currency_id, IF(LENGTH(deb_cred_uuid) = 36, HUID(deb_cred_uuid), NULL), NULL, comment, origin_id, user_id, cc_id, pc_id, TIMESTAMP(trans_date), CURRENT_TIMESTAMP()
  FROM bhima.general_ledger;

UPDATE general_ledger gl JOIN sale_record_map srm ON gl.trans_id = srm.trans_id SET gl.record_uuid = srm.uuid;
UPDATE posting_journal pj JOIN sale_record_map srm ON pj.trans_id = srm.trans_id SET pj.record_uuid = srm.uuid;

/* PERIOD TOTAL */
INSERT INTO period_total (enterprise_id, fiscal_year_id, period_id, account_id, credit, debit, locked)
SELECT enterprise_id, fiscal_year_id, period_id, account_id, credit, debit, locked FROM bhima.period_total;

/* PATIENT */
/*
  1.x DOESN'T LINK PATIENT TO USER WHO CREATE THE PATIENT,
  SO WE USE 2.X SUPERUSER ACCOUNT

  DEBTOR UUID WITH BAD GROUP : e27aecd1-5122-4c34-8aa6-1187edc8e597
  SELECT d.`uuid` FROM bhima.debitor d JOIN bhima.debitor_group dg ON dg.uuid = d.group_uuid WHERE dg.account_id IN (210, 257, 1074)
*/

-- drop the FULLTEXT index for a perf boost
ALTER TABLE `patient` DROP KEY `display_name`;

CREATE TEMPORARY TABLE patient_migration AS SELECT * FROM bhima.patient;

DELETE FROM patient_migration WHERE debitor_uuid = 'e27aecd1-5122-4c34-8aa6-1187edc8e597';

-- tshikaji doesn't require this.  Drop the constraint.
ALTER TABLE patient DROP KEY `patient_1`;
UPDATE patient_migration SET hospital_no = REPLACE(hospital_no, ' ', '');

CREATE TEMPORARY TABLE patient_hospital_no_dupes AS
  SELECT hospital_no, max(uuid) AS uuid FROM patient_migration GROUP BY hospital_no HAVING COUNT(hospital_no) > 1;

DELETE patient_migration FROM patient_migration INNER JOIN patient_hospital_no_dupes ph ON patient_migration.hospital_no = ph.hospital_no WHERE patient_migration.uuid <> ph.uuid;

-- 82 repeated patient references
CREATE TEMPORARY TABLE patient_reference_dupes AS
  SELECT project_id, reference, MIN(uuid) AS uuid, 0 AS 'n' FROM patient_migration GROUP BY project_id, reference HAVING COUNT(reference) > 1;

SET @m = (SELECT max(reference) FROM patient_migration);
UPDATE patient_reference_dupes SET n = (@m := @m + 1);

-- choose one project at random to shift up.  We will use HBB
UPDATE patient_migration pm JOIN patient_reference_dupes pd ON pm.uuid = pd.uuid SET pm.reference = pd.n;

/*!40000 ALTER TABLE `patient` DISABLE KEYS */;
INSERT INTO patient (
  `uuid`, project_id, reference, debtor_uuid, display_name, dob, dob_unknown_date, father_name, mother_name,
  profession, employer, spouse, spouse_profession, spouse_employer, sex, religion, marital_status,
  phone, email, address_1, address_2, registration_date, origin_location_id, current_location_id,
  title, notes, hospital_no, avatar, user_id, health_zone, health_area, created_at
)
SELECT
  HUID(`uuid`), project_id, reference, HUID(debitor_uuid), IFNULL(CONCAT(first_name, ' ', last_name, ' ', middle_name), 'Unknown'), dob, 0, father_name, mother_name,
  profession, employer, spouse, spouse_profession, spouse_employer, sex, religion, marital_status,
  phone, email, address_1, address_2, IF(registration_date = 0, CURRENT_DATE(), registration_date), HUID(origin_location_id), HUID(current_location_id),
  title, notes, hospital_no, NULL, 1000, NULL, NULL, IF(registration_date = 0, CURRENT_DATE(), registration_date)
FROM patient_migration;
/*!40000 ALTER TABLE `patient` ENABLE KEYS */;

DROP TABLE patient_migration;

/* CASH_BOX */

INSERT INTO cash_box (id, label, project_id, is_auxiliary)
  SELECT id, `text`, project_id, is_auxillary FROM bhima.cash_box;

/* CASH_BOX ACCOUNT CURRENCY */
INSERT INTO cash_box_account_currency (id, currency_id, cash_box_id, account_id, transfer_account_id)
  SELECT id, currency_id, cash_box_id, account_id, virement_account_id FROM bhima.cash_box_account_currency;

-- filter for the cash table

/* CASH */
/*
  c54a8769-3e4f-4899-bc43-ef896d3919b3 is a deb_cred_uuid with type D which doesn't exist in the debitor table in 1.x
  with as cash uuid 524475fb-9762-4051-960c-e5796a14d300
*/
/* TEMPORARY FOR JOURNAL AND GENERAL LEDGER */
/*!40000 ALTER TABLE `bhima`.`posting_journal` DISABLE KEYS */;
/*!40000 ALTER TABLE `bhima`.`general_ledger` DISABLE KEYS */;
CREATE TEMPORARY TABLE combined_ledger AS SELECT `uuid`, trans_id, account_id, debit, credit, deb_cred_uuid, inv_po_id, origin_id FROM (
  SELECT `uuid`, trans_id, account_id, debit, credit, deb_cred_uuid, inv_po_id, origin_id FROM bhima.posting_journal
  UNION ALL
  SELECT `uuid`, trans_id, account_id, debit, credit, deb_cred_uuid, inv_po_id, origin_id FROM bhima.general_ledger
) as combined;
/*!40000 ALTER TABLE `bhima`.`posting_journal` ENABLE KEYS */;
/*!40000 ALTER TABLE `bhima`.`general_ledger` ENABLE KEYS */;

/* INDEX IN COMBINED */
ALTER TABLE combined_ledger ADD INDEX `inv_po_id` (`inv_po_id`);

-- create a table we can manipulate
CREATE TEMPORARY TABLE migrate_primary_cash_item AS SELECT * FROM bhima.primary_cash_item;
ALTER TABLE migrate_primary_cash_item ADD INDEX `document_uuid` (`document_uuid`);

-- maps pci uuids onto transactions and prepares vouchers
CREATE TEMPORARY TABLE pci_ledger AS
  SELECT HUID(pc.uuid) uuid, MAX(l.trans_id) AS trans_id, MAX(pc.reference) reference, MAX(pc.cost) amount,
    MAX(pc.currency_id) currency_id, MAX(pc.date) `date`, MAX(pc.project_id) project_id, MAX(pc.description) description,
    MAX(pc.user_id) user_id, MAX(l.origin_id) origin_id
  FROM migrate_primary_cash_item pci
    JOIN combined_ledger l ON pci.document_uuid = l.inv_po_id
    JOIN bhima.primary_cash pc ON pci.primary_cash_uuid = pc.uuid
  GROUP BY pc.uuid;

/*
 NOTE: after this operation, we are still missing ~675 vouchers.

There are all made by user 18, thankfully.  We can use this to pre-filter the
combined ledger;
*/

/* VOUCHER */
INSERT INTO voucher (`uuid`, `date`, project_id, reference, currency_id, amount, description, user_id, created_at, type_id, reference_uuid)
  SELECT `uuid`, `date`, project_id, reference, currency_id, amount, description, user_id, date, origin_id, NULL
  FROM pci_ledger;

/*
USE INDEXES FOR SPEED GAINS
Can't index TEXT?  MAKE IT VARCHAR
*/
ALTER TABLE combined_ledger MODIFY trans_id VARCHAR(50);
ALTER TABLE pci_ledger MODIFY trans_id VARCHAR(50);
ALTER TABLE combined_ledger ADD INDEX `trans_id` (`trans_id`);
ALTER TABLE pci_ledger ADD INDEX `trans_id` (`trans_id`);

/* VOUCHER ITEM */
/* GET DATA DIRECTLY FROM POSTING JOURNAL AND GENERAL LEDGER */
INSERT INTO voucher_item (`uuid`, account_id, debit, credit, voucher_uuid, document_uuid, entity_uuid)
  SELECT HUID(UUID()), cl.account_id, cl.debit, cl.credit, pci_ledger.uuid, NULL, HUID(deb_cred_uuid)
  FROM pci_ledger JOIN combined_ledger cl ON pci_ledger.trans_id = cl.trans_id;

DROP TABLE combined_ledger;
DROP TABLE migrate_primary_cash_item;

ALTER TABLE pci_ledger DROP INDEX `trans_id`;
ALTER TABLE pci_ledger MODIFY `trans_id` TEXT CHARACTER SET utf8 COLLATE utf8_general_ci;

UPDATE general_ledger gl JOIN pci_ledger l ON gl.trans_id = l.trans_id SET gl.record_uuid = l.uuid;
UPDATE posting_journal pj JOIN pci_ledger l ON pj.trans_id = l.trans_id SET pj.record_uuid = l.uuid;

DROP TABLE pci_ledger;


/*
Vouchers - Create Reversals for Cash Payments

This following statements will create voucher reversals for vouchers.  The strategy
is to copy the posting journal transactions into vouchers.
*/

-- reconstitute cash reversals as voucher reversals. In the 1.x database, there are 1282 of them.
-- this is the 1.x transaction type for cash_discard
SET @typeCashDiscard = 26;
CREATE TEMPORARY TABLE cash_discard_migration AS
  SELECT project_id, trans_id, trans_date, description, account_id, debit, credit, currency_id, user_id FROM bhima.general_ledger
  WHERE origin_id = @typeCashDiscard;

INSERT INTO cash_discard_migration
  SELECT project_id, trans_id, trans_date, description, account_id, debit, credit, currency_id, user_id FROM bhima.posting_journal
  WHERE origin_id = @typeCashDiscard;

INSERT INTO voucher (`uuid`, `date`, project_id, reference, currency_id, amount, description, user_id, created_at, type_id, reference_uuid, edited)
  SELECT HUID(UUID()), MAX(trans_date), MAX(cd.project_id), NULL, MAX(currency_id), MAX(cd.cost), MAX(cdm.description), MAX(user_id), MAX(trans_date), @typeCashDiscard, MAX(HUID(cd.cash_uuid)), 0
  FROM cash_discard_migration cdm JOIN bhima.cash_discard cd ON cdm.description = cd.description
  GROUP BY trans_id;

INSERT INTO voucher_item (uuid, account_id, debit, credit, voucher_uuid, document_uuid, entity_uuid)
  SELECT HUID(UUID()), cdm.account_id, cdm.debit, cdm.credit, v.uuid, IF(cdm.credit > 0, HUID(cd.cash_uuid), NULL), IF(cdm.credit > 0, HUID(cd.debitor_uuid), NULL)
  FROM cash_discard_migration cdm JOIN bhima.cash_discard cd ON cdm.description = cd.description
    JOIN voucher v ON cdm.description = v.description;

DROP TABLE cash_discard_migration;

-- update links
CREATE TEMPORARY TABLE voucher_map AS SELECT uuid, description FROM voucher WHERE type_id = @typeCashDiscard;
CREATE TEMPORARY TABLE voucher_trans_map AS
  SELECT MAX(vm.uuid) uuid, MAX(vm.description) description, gl.trans_id
  FROM posting_journal gl JOIN voucher_map vm ON gl.description = vm.description
  GROUP BY gl.trans_id;

INSERT INTO voucher_trans_map
  SELECT MAX(vm.uuid) uuid, MAX(vm.description) description, gl.trans_id FROM
  general_ledger gl JOIN voucher_map vm ON gl.description = vm.description
  GROUP BY gl.trans_id;

UPDATE posting_journal gl JOIN voucher_trans_map vtm ON gl.trans_id = vtm.trans_id SET gl.record_uuid = vtm.uuid;
UPDATE general_ledger gl JOIN voucher_trans_map vtm ON gl.trans_id = vtm.trans_id SET gl.record_uuid = vtm.uuid;

/*
Vouchers - Create Reversals for Invoices (Credit Notes)

NOTE: thankfully, only one credit note per invoice. Confirm by:
select count(sale_uuid) n, sale_uuid FROM credit_note GROUP BY sale_uuid HAVING n > 1;
*/
SET @creditNoteType = 6;
SET @currencyId = 2;
CREATE TEMPORARY TABLE credit_note_migration AS
  SELECT project_id, trans_id, trans_date, description, account_id, debit, credit, currency_id, user_id FROM bhima.general_ledger
  WHERE origin_id = @creditNoteType;

INSERT INTO credit_note_migration
  SELECT project_id, trans_id, trans_date, description, account_id, debit, credit, currency_id, user_id FROM bhima.posting_journal
  WHERE origin_id = @creditNoteType;

CREATE TEMPORARY TABLE credit_note_uuids AS
  SELECT DISTINCT trans_id, HUID(UUID()) AS `uuid` FROM credit_note_migration;

INSERT INTO voucher (`uuid`, `date`, project_id, reference, currency_id, amount, description, user_id, created_at, type_id, reference_uuid, edited)
  SELECT MAX(cnu.uuid), MAX(trans_date), MAX(cn.project_id), NULL, MAX(currency_id), MAX(cn.cost), MAX(cnm.description), MAX(user_id), MAX(trans_date), @creditNoteType, MAX(HUID(cn.sale_uuid)), 0
  FROM credit_note_migration cnm JOIN bhima.credit_note cn ON cnm.description = cn.description
    JOIN credit_note_uuids AS cnu ON cnm.trans_id = cnu.trans_id
  GROUP BY cnm.trans_id;

INSERT INTO voucher_item (uuid, account_id, debit, credit, voucher_uuid, document_uuid, entity_uuid)
  SELECT HUID(UUID()), cnm.account_id, cnm.debit, cnm.credit, v.uuid, HUID(cn.sale_uuid), HUID(cn.debitor_uuid)
  FROM credit_note_migration cnm JOIN bhima.credit_note cn ON cnm.description = cn.description
    JOIN voucher v ON cnm.description = v.description
  WHERE v.type_id = @creditNoteType;

UPDATE posting_journal gl JOIN credit_note_uuids cnu ON gl.trans_id = cnu.trans_id SET gl.record_uuid = cnu.uuid WHERE gl.transaction_type_id = @creditNoteType;
UPDATE general_ledger gl JOIN credit_note_uuids cnu ON gl.trans_id = cnu.trans_id SET gl.record_uuid = cnu.uuid WHERE gl.transaction_type_id = @creditNoteType;

DROP TABLE credit_note_migration;
DROP TABLE credit_note_uuids;

INSERT INTO patient_group
  SELECT HUID(`uuid`), enterprise_id, HUID(`price_list_uuid`), name, IFNULL(note, ""), created FROM bhima.patient_group;

INSERT IGNORE INTO patient_assignment
  SELECT HUID(`uuid`), HUID(patient_group_uuid), HUID(patient_uuid) FROM bhima.assignation_patient;


-- deal with unmigrated types
-- import_automatique
CALL VouchersFromTransactionTypePJ(9);
CALL VouchersFromTransactionTypeGL(9);
-- distribution
CALL VouchersFromTransactionTypePJ(12);
CALL VouchersFromTransactionTypeGL(12);
-- stock loss
CALL VouchersFromTransactionTypePJ(13);
CALL VouchersFromTransactionTypeGL(13);
-- payroll
CALL VouchersFromTransactionTypePJ(14);
CALL VouchersFromTransactionTypeGL(14);
-- donation
CALL VouchersFromTransactionTypePJ(15);
CALL VouchersFromTransactionTypeGL(15);
-- tax_payment
CALL VouchersFromTransactionTypePJ(16);
CALL VouchersFromTransactionTypeGL(16);
-- cotisation_engagement
CALL VouchersFromTransactionTypePJ(17);
CALL VouchersFromTransactionTypeGL(17);
-- tax_engagement
CALL VouchersFromTransactionTypePJ(18);
CALL VouchersFromTransactionTypeGL(18);
-- cotisation_paiement
CALL VouchersFromTransactionTypePJ(19);
CALL VouchersFromTransactionTypeGL(19);
-- indirect_purchase
CALL VouchersFromTransactionTypePJ(21);
CALL VouchersFromTransactionTypeGL(21);
-- confirm_purchase
CALL VouchersFromTransactionTypePJ(22);
CALL VouchersFromTransactionTypeGL(22);
-- salary_advance
CALL VouchersFromTransactionTypePJ(23);
CALL VouchersFromTransactionTypeGL(23);
-- employee_invoice
CALL VouchersFromTransactionTypePJ(24);
CALL VouchersFromTransactionTypeGL(24);
-- cash_return
CALL VouchersFromTransactionTypePJ(27);
CALL VouchersFromTransactionTypeGL(27);
-- reversing_stock
CALL VouchersFromTransactionTypePJ(28);
CALL VouchersFromTransactionTypeGL(28);
-- confirmation_integration
CALL VouchersFromTransactionTypePJ(32);
CALL VouchersFromTransactionTypeGL(32);

-- clean up group_invoice
DELETE FROM voucher_item WHERE voucher_uuid IN (SELECT uuid FROM voucher WHERE type_id = 33);
DELETE FROM voucher WHERE type_id = 33;
CALL VouchersFromTransactionTypePJ(33);
CALL VouchersFromTransactionTypeGL(33);

-- service_return_stock
CALL VouchersFromTransactionTypePJ(34);
CALL VouchersFromTransactionTypeGL(34);

-- WARNING: cash is last because it takes the longest
-- select project_id, reference, count(reference) n from cash GROUP BY project_id, reference HAVING n > 1;
CREATE TEMPORARY TABLE cash_migrate AS SELECT * FROM bhima.cash ORDER BY bhima.cash.uuid;
ALTER TABLE cash_migrate ADD INDEX `uuid` (`uuid`);

-- we have duplicate references to clean up
CREATE TEMPORARY TABLE cash_reference_dupes AS
  SELECT project_id, reference, MIN(uuid) AS uuid, 0 AS 'n' FROM cash_migrate GROUP BY project_id, reference HAVING COUNT(reference) > 1;

SET @c = (SELECT max(reference) FROM cash_migrate);
UPDATE cash_reference_dupes SET n = (@c := @c + 1);

-- choose one project at random to shift up.  We will use HBB
UPDATE cash_migrate cm JOIN cash_reference_dupes cd ON cm.uuid = cd.uuid SET cm.reference = cd.n;

CREATE TEMPORARY TABLE reversed_cash_payments AS SELECT HUID(cash_uuid) AS `uuid` FROM bhima.cash_discard;
ALTER TABLE reversed_cash_payments ADD INDEX `uuid` (`uuid`);

INSERT INTO cash (`uuid`, project_id, reference, `date`, debtor_uuid, currency_id, amount, user_id, cashbox_id, description, is_caution, reversed, edited, created_at)
  SELECT HUID(cm.uuid), cm.project_id, cm.reference, cm.`date`, HUID(cm.deb_cred_uuid), cm.currency_id, cm.cost, cm.user_id, cm.cashbox_id, cm.description, cm.is_caution, 0, 0, CURRENT_TIMESTAMP()
  FROM cash_migrate cm;

UPDATE cash SET reversed = 1 WHERE cash.uuid IN (SELECT uuid from reversed_cash_payments);

/* CASH ITEM */
/*
  skipped cash 524475fb-9762-4051-960c-e5796a14d30
*/
INSERT INTO cash_item (`uuid`, cash_uuid, amount, invoice_uuid)
  SELECT HUID(`uuid`), HUID(cash_uuid), allocated_cost, HUID(invoice_uuid) FROM bhima.cash_item;

CREATE TEMPORARY TABLE `cash_record_map` AS SELECT HUID(c.uuid) AS uuid, p.trans_id FROM bhima.cash c JOIN bhima.posting_journal p ON c.uuid = p.inv_po_id;
INSERT INTO `cash_record_map` SELECT HUID(c.uuid) AS uuid, p.trans_id FROM bhima.cash c JOIN bhima.general_ledger p ON c.uuid = p.inv_po_id;

UPDATE posting_journal pj JOIN cash_record_map crm ON pj.trans_id = crm.trans_id SET pj.record_uuid = crm.uuid;
UPDATE general_ledger gl JOIN cash_record_map crm ON gl.trans_id = crm.trans_id SET gl.record_uuid = crm.uuid;

DROP TABLE cash_reference_dupes;
DROP TABLE cash_migrate;

/*
Linking - Journal/General Ledger

Update Journal + GL make cash payments reference invoices.

*/
CREATE TEMPORARY TABLE invoice_links AS
  SELECT gl.uuid, ci.invoice_uuid FROM cash_item ci JOIN general_ledger gl ON
    ci.cash_uuid = gl.record_uuid AND
    ci.amount = gl.credit AND
    gl.entity_uuid IS NOT NULL;

INSERT INTO invoice_links
  SELECT gl.uuid, ci.invoice_uuid FROM cash_item ci JOIN posting_journal gl ON
    ci.cash_uuid = gl.record_uuid AND
    ci.amount = gl.credit AND
    gl.entity_uuid IS NOT NULL;

UPDATE general_ledger gl JOIN invoice_links iv ON gl.uuid = iv.uuid SET gl.reference_uuid = iv.invoice_uuid;
UPDATE posting_journal gl JOIN invoice_links iv ON gl.uuid = iv.uuid SET gl.reference_uuid = iv.invoice_uuid;

DROP TABLE invoice_links;

COMMIT;

/* ENABLE AUTOCOMMIT AFTER THE SCRIPT */
SET autocommit=1;
SET foreign_key_checks=1;
SET unique_checks=1;

/* RECOMPUTE */
Call ComputeAccountClass();
Call zRecomputeEntityMap();
Call zRecomputeDocumentMap();
Call zRecalculatePeriodTotals();

DROP PROCEDURE MergeSector;
DROP PROCEDURE VouchersFromTransactionTypeGL;
DROP PROCEDURE VouchersFromTransactionTypePJ;

-- compute period 0 for the following fiscal years
CALL ComputePeriodZero(2015);
CALL ComputePeriodZero(2016);
CALL ComputePeriodZero(2017);
CALL ComputePeriodZero(2018);
