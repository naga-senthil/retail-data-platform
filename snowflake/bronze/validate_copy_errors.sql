
SELECT *
FROM TABLE(
    VALIDATE(
        RETAIL_DW.BRONZE.<% TABLE_NAME %>,
        JOB_ID => '<% QUERY_ID %>'
    )
);
