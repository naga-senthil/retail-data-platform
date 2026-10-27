SELECT
    FILE_PATH,
    BATCH_ID,
    CASE
        WHEN FILE_PATH LIKE '%/orders.csv'
            THEN 'orders'
        WHEN FILE_PATH LIKE '%/order_items.csv'
            THEN 'order_items'
        WHEN FILE_PATH LIKE '%/order_payments.csv'
            THEN 'order_payments'
        WHEN FILE_PATH LIKE '%/order_reviews.csv'
            THEN 'order_reviews'
    END AS TABLE_KEY
FROM RETAIL_DW.BRONZE.STAGE_FILE_LOG S
WHERE FILE_CATEGORY = 'DAILY'
  AND UPLOAD_STATUS = 'UPLOADED'
  AND NOT EXISTS (
      SELECT 1
      FROM RETAIL_DW.BRONZE.LOAD_AUDIT A
      WHERE A.FILE_PATH = S.FILE_PATH
        AND A.LOAD_STATUS = 'SUCCESS'
  )
ORDER BY BATCH_ID, FILE_PATH;