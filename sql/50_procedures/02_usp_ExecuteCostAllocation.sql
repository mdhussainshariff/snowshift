-- PROCEDURE 2: Execute Cost Allocation
-- Extracted from the original 1.Main.sql monolith; deployed via manifest.yaml.

CREATE OR REPLACE PROCEDURE SNOWCONVERT_DEMO.PLANNING.USP_EXECUTECOSTALLOCATION("BUDGET_HEADER_ID" NUMBER(38,0), "ALLOCATION_BASIS_OVERRIDE" VARCHAR DEFAULT null, "DRY_RUN" BOOLEAN DEFAULT FALSE, "INCLUDE_ZERO_AMOUNTS" BOOLEAN DEFAULT FALSE)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS '
DECLARE
    v_start_time TIMESTAMP_NTZ := CURRENT_TIMESTAMP();
    v_total_allocated DECIMAL(19,4) := 0;
    v_rules_processed INT := 0;
    v_error_count INT := 0;
    v_result_json VARIANT;
    v_journal_id NUMBER;
    EX_BUDGET_HEADER_REQUIRED EXCEPTION (-20001, ''Budget header ID is required'');
BEGIN
    IF (budget_header_id IS NULL) THEN
        RAISE EX_BUDGET_HEADER_REQUIRED;
    END IF;

    CREATE TEMPORARY TABLE IF NOT EXISTS temp_allocation_rules AS
    SELECT
        ar.AllocationRuleID,
        ar.RuleCode,
        ar.RuleName,
        ar.ExecutionSequence,
        ar.AllocationBasis,
        0 AS is_processed
    FROM Planning.AllocationRule ar
    WHERE ar.IsActive = TRUE
    ORDER BY ar.ExecutionSequence;

    v_rules_processed := (SELECT COUNT(*) FROM temp_allocation_rules);

    IF (:dry_run = FALSE) THEN
        INSERT INTO Planning.ConsolidationJournal (
            JournalNumber,
            JournalType,
            BudgetHeaderID,
            FiscalPeriodID,
            PostingDate,
            Description,
            StatusCode
        )
        SELECT
            ''ALLOC-'' || TO_CHAR(CURRENT_TIMESTAMP(), ''YYYYMMDDHH24MISS''),
            ''ALLOCATION'',
            :budget_header_id,
            bh.StartPeriodID,
            CURRENT_DATE(),
            ''Cost allocation for budget '' || bh.BudgetCode,
            ''DRAFT''
        FROM Planning.BudgetHeader bh
        WHERE bh.BudgetHeaderID = :budget_header_id;

        v_journal_id := (SELECT MAX(JournalID) FROM Planning.ConsolidationJournal WHERE JournalType = ''ALLOCATION'' AND BudgetHeaderID = :budget_header_id);

        INSERT INTO Planning.ConsolidationJournalLine (
            JournalID,
            LineNumber,
            GLAccountID,
            CostCenterID,
            DebitAmount,
            CreditAmount,
            NetAmount,
            CreatedDateTime
        )
        SELECT
            :v_journal_id,
            ROW_NUMBER() OVER (ORDER BY bli.BudgetLineItemID),
            bli.GLAccountID,
            bli.CostCenterID,
            bli.FinalAmount,
            0,
            bli.FinalAmount,
            CURRENT_TIMESTAMP()
        FROM Planning.BudgetLineItem bli
        WHERE bli.BudgetHeaderID = :budget_header_id;

        v_total_allocated := (SELECT COALESCE(SUM(FinalAmount), 0) FROM Planning.BudgetLineItem WHERE BudgetHeaderID = :budget_header_id);
    END IF;

    v_result_json := OBJECT_CONSTRUCT(
        ''allocation_start'', v_start_time,
        ''allocation_end'', CURRENT_TIMESTAMP(),
        ''rules_processed'', v_rules_processed,
        ''total_allocated'', v_total_allocated,
        ''error_count'', v_error_count,
        ''dry_run'', :dry_run,
        ''allocation_basis_override'', :allocation_basis_override,
        ''status'', ''SUCCESS''
    );

    RETURN v_result_json;
END;
';
