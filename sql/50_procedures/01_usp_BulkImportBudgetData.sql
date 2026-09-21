-- PROCEDURE 1: Bulk Import Budget Data
-- Extracted from the original 1.Main.sql monolith; deployed via manifest.yaml.

CREATE OR REPLACE PROCEDURE SNOWCONVERT_DEMO.PLANNING.USP_BULKIMPORTBUDGETDATA("IMPORT_SOURCE" VARCHAR, "TARGET_BUDGET_HEADER_ID" NUMBER(38,0), "FILE_PATH" VARCHAR DEFAULT null, "BUDGET_DATA" VARIANT DEFAULT null, "STAGING_TABLE_NAME" VARCHAR DEFAULT null, "VALIDATION_MODE" VARCHAR DEFAULT 'STRICT', "DUPLICATE_HANDLING" VARCHAR DEFAULT 'REJECT', "BATCH_SIZE" NUMBER(38,0) DEFAULT 10000, "USE_PARALLEL_LOAD" BOOLEAN DEFAULT TRUE)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS '
DECLARE
    v_start_time TIMESTAMP_NTZ := CURRENT_TIMESTAMP();
    v_import_batch_id VARCHAR(36) := UUID_STRING();
    v_total_rows INT := 0;
    v_valid_rows INT := 0;
    v_invalid_rows INT := 0;
    v_result_json VARIANT;
BEGIN
    CREATE TEMPORARY TABLE temp_import_staging (
        row_id INT AUTOINCREMENT PRIMARY KEY,
        gl_account_id INT,
        account_number VARCHAR(20),
        cost_center_id INT,
        cost_center_code VARCHAR(20),
        fiscal_period_id INT,
        fiscal_year SMALLINT,
        fiscal_month TINYINT,
        original_amount DECIMAL(19,4),
        adjusted_amount DECIMAL(19,4),
        spread_method_code VARCHAR(10),
        notes VARCHAR(500),
        is_valid BOOLEAN DEFAULT TRUE,
        validation_errors VARCHAR(4000),
        is_processed BOOLEAN DEFAULT FALSE
    );
    
    IF (import_source = ''VARIANT'') THEN
        INSERT INTO temp_import_staging (
            account_number, cost_center_code, fiscal_year, fiscal_month,
            original_amount, adjusted_amount, spread_method_code, notes
        )
        SELECT 
            value:account_number::VARCHAR,
            value:cost_center_code::VARCHAR,
            value:fiscal_year::SMALLINT,
            value:fiscal_month::TINYINT,
            value:original_amount::DECIMAL(19,4),
            value:adjusted_amount::DECIMAL(19,4),
            value:spread_method_code::VARCHAR,
            value:notes::VARCHAR
        FROM TABLE(FLATTEN(INPUT => :budget_data));
        
        v_total_rows := (SELECT COUNT(*) FROM temp_import_staging);
    END IF;
    
    IF (validation_mode IN (''STRICT'', ''LENIENT'')) THEN
        UPDATE temp_import_staging
        SET is_valid = FALSE,
            validation_errors = ''Missing required fields''
        WHERE gl_account_id IS NULL 
        OR cost_center_id IS NULL 
        OR original_amount IS NULL;
    END IF;
    
    INSERT INTO Planning.BudgetLineItem (
        BudgetHeaderID, GLAccountID, CostCenterID, FiscalPeriodID,
        OriginalAmount, AdjustedAmount, FinalAmount, SpreadMethodCode,
        LastModifiedDateTime
    )
    SELECT 
        :target_budget_header_id,
        tis.gl_account_id,
        tis.cost_center_id,
        tis.fiscal_period_id,
        tis.original_amount,
        COALESCE(tis.adjusted_amount, 0),
        tis.original_amount + COALESCE(tis.adjusted_amount, 0),
        tis.spread_method_code,
        CURRENT_TIMESTAMP()
    FROM temp_import_staging tis
    WHERE tis.is_valid = TRUE;
    
    v_valid_rows := SQLROWCOUNT;
    v_invalid_rows := v_total_rows - v_valid_rows;
    
    v_result_json := OBJECT_CONSTRUCT(
        ''import_batch_id'', v_import_batch_id,
        ''import_source'', :import_source,
        ''total_rows_loaded'', v_total_rows,
        ''rows_imported'', v_valid_rows,
        ''rows_rejected'', v_invalid_rows,
        ''status'', CASE WHEN v_invalid_rows = 0 THEN ''SUCCESS'' ELSE ''PARTIAL_SUCCESS'' END
    );
    
    DROP TABLE IF EXISTS temp_import_staging;
    
    RETURN v_result_json;
END;
';
