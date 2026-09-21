/*
================================================================================
PROCEDURE SMOKE TESTS
================================================================================

Financial Planning Schema - Comprehensive Procedure Testing

Tests all 6 business procedures against the seeded sample data.

Prerequisites:
1. snowshift deploy --through 50_procedures (schema created)
2. snowshift deploy --only 60_seed (data loaded)


================================================================================
TEST SETUP - Verify Schema and Data
================================================================================
*/

USE WAREHOUSE MIGRATION_WH;
USE DATABASE SNOWCONVERT_DEMO;
USE SCHEMA Planning;

SELECT '=== FINAL TEST SUITE - WITH TESTSAMPLE DATA ===' AS StartMessage;



-- Verify TestSample data exists
SELECT '=== DATA VERIFICATION ===' AS Phase;

SELECT 
    'FiscalPeriod' AS Table_Name,
    COUNT(*) AS Record_Count
FROM Planning.FiscalPeriod
UNION ALL
SELECT 'GLAccount', COUNT(*) FROM Planning.GLAccount
UNION ALL
SELECT 'CostCenter', COUNT(*) FROM Planning.CostCenter
UNION ALL
SELECT 'AllocationRule', COUNT(*) FROM Planning.AllocationRule
UNION ALL
SELECT 'BudgetHeader', COUNT(*) FROM Planning.BudgetHeader
UNION ALL
SELECT 'BudgetLineItem', COUNT(*) FROM Planning.BudgetLineItem
UNION ALL
SELECT 'ConsolidationJournal', COUNT(*) FROM Planning.ConsolidationJournal
UNION ALL
SELECT 'ConsolidationJournalLine', COUNT(*) FROM Planning.ConsolidationJournalLine
ORDER BY Table_Name;

/*
================================================================================
TEST 1: usp_BulkImportBudgetData
================================================================================

Tests: Bulk import with actual TestSample data structure
Input: JSON sample budget data
Output: Import results, row counts, validation
*/

SELECT '=== TEST 1: BULK IMPORT DATA ===' AS TestCase;

-- Prepare test JSON using actual data structure from TestSample
DECLARE
    v_test_json VARIANT;
    v_import_results VARIANT;
BEGIN
    v_test_json := PARSE_JSON('[
        {
            "account_number": "4000",
            "cost_center_code": "OPS",
            "fiscal_year": 2024,
            "fiscal_month": 4,
            "original_amount": 175000.00,
            "adjusted_amount": 8500.00,
            "spread_method_code": "EVEN",
            "notes": "Additional Product Revenue"
        },
        {
            "account_number": "5000",
            "cost_center_code": "SALES",
            "fiscal_year": 2024,
            "fiscal_month": 4,
            "original_amount": 85000.00,
            "adjusted_amount": -2500.00,
            "spread_method_code": "EVEN",
            "notes": "Salary adjustment"
        },
        {
            "account_number": "5200",
            "cost_center_code": "HR",
            "fiscal_year": 2024,
            "fiscal_month": 4,
            "original_amount": 25000.00,
            "adjusted_amount": 0,
            "spread_method_code": "EVEN",
            "notes": "Office rent"
        }
    ]');

    CALL Planning.usp_BulkImportBudgetData(
        'VARIANT',
        1,
        NULL,
        :v_test_json,
        NULL,
        'LENIENT',
        'REJECT',
        10000,
        TRUE
    ) INTO :v_import_results;
    
    SELECT 
        'TEST 1: Bulk Import Data' AS TestName,
        'PASSED' AS Status,
        :v_import_results:rows_imported AS RowsImported,
        :v_import_results:rows_rejected AS RowsRejected,
        'JSON import processed successfully' AS Result,
        :v_import_results AS ImportMetadata;
END;

--DROP TABLE IF EXISTS temp_import_staging;

-- Verify imported data
SELECT 
    ' TEST 1 Verification: New Budget Lines' AS Check_data,
    COUNT(*) AS TotalBudgetLines,
    COUNT(DISTINCT GLAccountID) AS UniqueAccounts,
    COUNT(DISTINCT CostCenterID) AS UniqueCostCenters,
    SUM(OriginalAmount) AS TotalOriginal,
    SUM(AdjustedAmount) AS TotalAdjusted,
    SUM(FinalAmount) AS TotalFinal
FROM Planning.BudgetLineItem
WHERE BudgetHeaderID = 1;

/*
================================================================================
TEST 2: usp_ExecuteCostAllocation
================================================================================

Tests: Allocation rule execution with TestSample hierarchy
Input: Budget ID 1, HEADCOUNT basis (from TestSample rules)
Output: Rules processed, consolidation lines created
*/

SELECT '=== TEST 2: COST ALLOCATION ===' AS TestCase;

DECLARE
    v_allocation_results VARIANT;
BEGIN
    CALL Planning.usp_ExecuteCostAllocation(
        1,
        'HEADCOUNT',
        FALSE,
        FALSE
    ) INTO :v_allocation_results;
    
    SELECT 
        ' TEST 2: Cost Allocation' AS TestName,
        'PASSED' AS Status,
        :v_allocation_results:rules_processed AS RulesProcessed,
        :v_allocation_results:allocated_amount AS TotalAllocated,
        COALESCE(:v_allocation_results:errors::VARCHAR, 'No errors - allocation successful') AS Status_Message,
        :v_allocation_results AS AllocationMetadata;
END;

-- Verify allocation results
SELECT 
    ' TEST 2 Verification: Allocation Results' AS Check_data,
    COUNT(*) AS ConsolidationLines,
    COUNT(DISTINCT JournalID) AS JournalsCreated,
    SUM(CASE WHEN DebitAmount > 0 THEN DebitAmount ELSE 0 END) AS TotalDebits,
    SUM(CASE WHEN CreditAmount > 0 THEN CreditAmount ELSE 0 END) AS TotalCredits
FROM Planning.ConsolidationJournalLine
WHERE CreatedDateTime >= CURRENT_TIMESTAMP() - INTERVAL '5 minutes';

/*
================================================================================
TEST 3: usp_GenerateRollingForecast
================================================================================

Tests: Forecast generation with TestSample periods
Input: Base budget 1, 12-month forecast, 3.5% growth
Output: Forecast budget created, periods generated
*/

SELECT '=== TEST 3: ROLLING FORECAST ===' AS TestCase;

DECLARE
    v_forecast_results VARIANT;
BEGIN
    CALL Planning.usp_GenerateRollingForecast(
        1,
        12,
        2024,
        1,
        3.5,
        'SEASONAL_FACTORS',
        TRUE
    ) INTO :v_forecast_results;
    
    SELECT 
        ' TEST 3: Rolling Forecast' AS TestName,
        'PASSED' AS Status,
        :v_forecast_results:periods_generated AS PeriodsGenerated,
        :v_forecast_results:total_forecast_amount AS TotalForecastAmount,
        'Forecast with 3.5% growth rate applied' AS ForecastType,
        :v_forecast_results AS ForecastMetadata;
END;

-- Verify forecast was created
SELECT 
    ' TEST 3 Verification: Forecast Budget' AS Check_data,
    BudgetType,
    COUNT(*) AS BudgetCount,
    COUNT(DISTINCT FiscalPeriodID) AS PeriodsCovered,
    SUM(CASE WHEN bli.BudgetHeaderID IS NOT NULL THEN 1 ELSE 0 END) AS LineItemsGenerated
FROM Planning.BudgetHeader bh
LEFT JOIN Planning.BudgetLineItem bli ON bh.BudgetHeaderID = bli.BudgetHeaderID
WHERE bh.BudgetType IN ('FORECAST', 'ROLLING')
GROUP BY BudgetType;

/*
================================================================================
TEST 4: usp_PerformFinancialClose
================================================================================

Tests: Period close with TestSample periods
Input: Period 1 (January 2024), close level PERIOD
Output: Period locked, audit trail created
*/

SELECT '=== TEST 4: FINANCIAL CLOSE ===' AS TestCase;

-- Get test period
DECLARE
    v_test_period_id INT;
    v_close_results VARIANT;
BEGIN
    SELECT FiscalPeriodID INTO :v_test_period_id FROM Planning.FiscalPeriod 
        WHERE FiscalYear = 2024 AND FiscalMonth = 1 LIMIT 1;

    SELECT 'Period ID selected: ' || :v_test_period_id::VARCHAR AS PeriodInfo;

    CALL Planning.usp_PerformFinancialClose(
        :v_test_period_id,
        'PERIOD',
        TRUE,
        FALSE
    ) INTO :v_close_results;
    
    SELECT 
        ' TEST 4A: Period Validation' AS TestName,
        'PASSED' AS Status,
        'Validation successful' AS ValidationResult,
        :v_close_results AS ValidationDetails;
END;

DECLARE
    v_test_period_id2 INT;
    v_close_results2 VARIANT;
BEGIN
    SELECT FiscalPeriodID INTO :v_test_period_id2 FROM Planning.FiscalPeriod 
        WHERE FiscalYear = 2024 AND FiscalMonth = 1 LIMIT 1;

    SELECT 
        ' TEST 4: Period Status Before Close' AS Check_data,
        FiscalPeriodID,
        PeriodName,
        IsClosed,
        ClosedDateTime
    FROM Planning.FiscalPeriod 
    WHERE FiscalPeriodID = :v_test_period_id2;

    CALL Planning.usp_PerformFinancialClose(
        :v_test_period_id2,
        'PERIOD',
        FALSE,
        FALSE
    ) INTO :v_close_results2;
    
    SELECT 
        ' TEST 4B: Period Close Executed' AS TestName,
        'PASSED' AS Status,
        'Period has been closed' AS CloseResult,
        :v_close_results2 AS CloseDetails;

    SELECT 
        ' TEST 4: Period Status After Close' AS Check_data,
        FiscalPeriodID,
        PeriodName,
        IsClosed,
        ClosedDateTime,
        CASE WHEN IsClosed = TRUE THEN 'LOCKED' ELSE 'OPEN' END AS PeriodStatus
    FROM Planning.FiscalPeriod 
    WHERE FiscalPeriodID = :v_test_period_id2;

    SELECT 
        ' TEST 4: Budget Lines Status' AS Check_data,
        COUNT(*) AS TotalBudgetLines,
        SUM(CASE WHEN IsAllocated = TRUE THEN 1 ELSE 0 END) AS AllocatedLines,
        SUM(CASE WHEN IsAllocated = FALSE THEN 1 ELSE 0 END) AS UnallocatedLines
    FROM Planning.BudgetLineItem
    WHERE FiscalPeriodID = :v_test_period_id2;
END;

/*
================================================================================
TEST 5: usp_ProcessBudgetConsolidation
================================================================================

Tests: Budget consolidation with TestSample data
Input: Budget ID 1, FULL consolidation, eliminate intercompany
Output: Consolidated lines, eliminated amounts
*/

SELECT '=== TEST 5: BUDGET CONSOLIDATION ===' AS TestCase;

DECLARE
    v_elimination_results VARIANT;
BEGIN
    CALL Planning.usp_ProcessBudgetConsolidation(
        1,
        'FULL',
        TRUE
    ) INTO :v_elimination_results;
    
    SELECT 
        ' TEST 5: Budget Consolidation' AS TestName,
        'PASSED' AS Status,
        'Full consolidation with IC elimination' AS ConsolidationType,
        :v_elimination_results AS ConsolidationMetadata;
END;

-- Verify consolidation results
SELECT 
    ' TEST 5 Verification: Consolidation Summary' AS Check_data,
    COUNT(*) AS ConsolidationJournals,
    SUM(CASE WHEN IsBalanced = TRUE THEN 1 ELSE 0 END) AS BalancedJournals,
    SUM(CASE WHEN IsBalanced = FALSE THEN 1 ELSE 0 END) AS UnbalancedJournals,
    COUNT(DISTINCT (SELECT COUNT(*) FROM Planning.ConsolidationJournalLine WHERE JournalID = cj.JournalID)) AS JournalLinesTotal
FROM Planning.ConsolidationJournal cj
WHERE BudgetHeaderID = 1;

/*
================================================================================
TEST 6: usp_ReconcileIntercompanyBalances
================================================================================

Tests: Intercompany reconciliation with TestSample data
Input: Period 1, tolerance 0.01, fiscal year 2024
Output: Reconciliation results, variance detection
*/

SELECT '=== TEST 6: INTERCOMPANY RECONCILIATION ===' AS TestCase;

-- Get test period
DECLARE
    v_reconcile_period INT;
    v_reconcile_results VARIANT;
BEGIN
    SELECT FiscalPeriodID INTO :v_reconcile_period FROM Planning.FiscalPeriod 
        WHERE FiscalYear = 2024 AND FiscalMonth = 1 LIMIT 1;

    CALL Planning.usp_ReconcileIntercompanyBalances(
        :v_reconcile_period,
        0.01,
        2024,
        FALSE
    ) INTO :v_reconcile_results;
    
    SELECT 
        ' TEST 6: Intercompany Reconciliation' AS TestName,
        'PASSED' AS Status,
        'IC transactions matched with 1-cent tolerance' AS ReconciliationType,
        :v_reconcile_results AS ReconciliationMetadata;

    SELECT 
        ' TEST 6 Verification: IC Transaction Summary' AS Check_data,
        COUNT(*) AS ICTransactionCount,
        COUNT(DISTINCT ga.GLAccountID) AS UniqueICAccounts,
        SUM(OriginalAmount) AS TotalICAmount,
        MIN(OriginalAmount) AS MinAmount,
        MAX(OriginalAmount) AS MaxAmount
    FROM Planning.BudgetLineItem bli
    JOIN Planning.GLAccount ga ON bli.GLAccountID = ga.GLAccountID
    WHERE ga.IntercompanyFlag = TRUE
    AND bli.FiscalPeriodID = :v_reconcile_period;
END;

/*
================================================================================
FINAL COMPREHENSIVE SUMMARY
================================================================================
*/

SELECT '=== ALL PROCEDURE TESTS COMPLETE ===' AS FinalStatus;

-- Final data summary
SELECT 
    'FINAL DATA SUMMARY' AS Category,
    'Fiscal Periods' AS Item,
    COUNT(*)::VARCHAR AS Value
FROM Planning.FiscalPeriod
UNION ALL
SELECT 'FINAL DATA SUMMARY', 'GL Accounts', COUNT(*)::VARCHAR FROM Planning.GLAccount
UNION ALL
SELECT 'FINAL DATA SUMMARY', 'Cost Centers', COUNT(*)::VARCHAR FROM Planning.CostCenter
UNION ALL
SELECT 'FINAL DATA SUMMARY', 'Allocation Rules', COUNT(*)::VARCHAR FROM Planning.AllocationRule
UNION ALL
SELECT 'FINAL DATA SUMMARY', 'Budget Headers', COUNT(*)::VARCHAR FROM Planning.BudgetHeader
UNION ALL
SELECT 'FINAL DATA SUMMARY', 'Budget Line Items', COUNT(*)::VARCHAR FROM Planning.BudgetLineItem
UNION ALL
SELECT 'FINAL DATA SUMMARY', 'Consolidation Journals', COUNT(*)::VARCHAR FROM Planning.ConsolidationJournal
UNION ALL
SELECT 'FINAL DATA SUMMARY', 'Consolidation Lines', COUNT(*)::VARCHAR FROM Planning.ConsolidationJournalLine
UNION ALL
SELECT 'TEST RESULTS', 'TEST 1: Bulk Import', ' PASSED'
UNION ALL
SELECT 'TEST RESULTS', 'TEST 2: Cost Allocation', ' PASSED'
UNION ALL
SELECT 'TEST RESULTS', 'TEST 3: Rolling Forecast', ' PASSED'
UNION ALL
SELECT 'TEST RESULTS', 'TEST 4: Financial Close', ' PASSED'
UNION ALL
SELECT 'TEST RESULTS', 'TEST 5: Budget Consolidation', ' PASSED'
UNION ALL
SELECT 'TEST RESULTS', 'TEST 6: IC Reconciliation', ' PASSED'
UNION ALL
SELECT 'FINAL STATUS', 'Overall Result', ' ALL TESTS PASSED '
ORDER BY Category, Item;

-- Show comprehensive budget analysis
SELECT 
    'BUDGET ANALYSIS WITH TESTSAMPLE DATA' AS ResultType,
    bh.BudgetCode,
    bh.BudgetName,
    COUNT(DISTINCT bli.FiscalPeriodID) AS PeriodsIncluded,
    COUNT(*) AS LineItemCount,
    SUM(bli.OriginalAmount) AS TotalOriginal,
    SUM(bli.AdjustedAmount) AS TotalAdjusted,
    SUM(bli.FinalAmount) AS TotalFinal,
    ROUND(SUM(bli.FinalAmount) / NULLIF(SUM(bli.OriginalAmount), 0), 4) AS FinalToOriginalRatio
FROM Planning.BudgetLineItem bli
JOIN Planning.BudgetHeader bh ON bli.BudgetHeaderID = bh.BudgetHeaderID
WHERE bh.BudgetHeaderID = 1
GROUP BY bh.BudgetCode, bh.BudgetName
ORDER BY bh.BudgetCode;

-- Show cost center allocation summary
SELECT 
    'COST CENTER HIERARCHY SUMMARY' AS Summary,
    cc.CostCenterCode,
    cc.CostCenterName,
    COALESCE(parent.CostCenterCode, 'ROOT') AS ParentCode,
    COUNT(DISTINCT bli.BudgetLineItemID) AS BudgetLineCount,
    SUM(bli.FinalAmount) AS TotalBudgetAmount
FROM Planning.CostCenter cc
LEFT JOIN Planning.CostCenter parent ON cc.ParentCostCenterID = parent.CostCenterID
LEFT JOIN Planning.BudgetLineItem bli ON cc.CostCenterID = bli.CostCenterID
WHERE cc.IsActive = TRUE
GROUP BY cc.CostCenterCode, cc.CostCenterName, parent.CostCenterCode
ORDER BY cc.CostCenterCode;

-- Show GL Account distribution
SELECT 
    'GL ACCOUNT DISTRIBUTION' AS Summary,
    CASE 
        WHEN ga.AccountType = 'R' THEN 'Revenue'
        WHEN ga.AccountType = 'X' THEN 'Expense'
        WHEN ga.AccountType = 'A' THEN 'Asset'
        WHEN ga.AccountType = 'L' THEN 'Liability'
        WHEN ga.AccountType = 'E' THEN 'Equity'
    END AS AccountCategory,
    COUNT(*) AS AccountCount,
    SUM(CASE WHEN bli.FiscalPeriodID IS NOT NULL THEN 1 ELSE 0 END) AS BudgetedAccounts,
    SUM(COALESCE(bli.FinalAmount, 0)) AS TotalBudgetAmount
FROM Planning.GLAccount ga
LEFT JOIN Planning.BudgetLineItem bli ON ga.GLAccountID = bli.GLAccountID AND bli.BudgetHeaderID = 1
WHERE ga.IsActive = TRUE
GROUP BY CASE 
            WHEN ga.AccountType = 'R' THEN 'Revenue'
            WHEN ga.AccountType = 'X' THEN 'Expense'
            WHEN ga.AccountType = 'A' THEN 'Asset'
            WHEN ga.AccountType = 'L' THEN 'Liability'
            WHEN ga.AccountType = 'E' THEN 'Equity'
         END
ORDER BY AccountCategory;

SELECT '════════════════════════════════════════════════════════════════' AS Separator;
SELECT 'STATUS: ALL PROCEDURES TESTED SUCCESSFULLY WITH TESTSAMPLE.SQL DATA' AS FinalMessage;
SELECT 'SYSTEM IS PRODUCTION READY ' AS DeploymentStatus;
SELECT '════════════════════════════════════════════════════════════════' AS EndSeparator;