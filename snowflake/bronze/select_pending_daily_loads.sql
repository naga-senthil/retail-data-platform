
SELECT
    S.FILE_PATH,
    S.BATCH_ID,
    CASE
        WHEN S.FILE_PATH LIKE '%/orders.csv'
            THEN 'orders'
        WHEN S.FILE_PATH LIKE '%/order_items.csv'
            THEN 'order_items'
        WHEN S.FILE_PATH LIKE '%/order_payments.csv'
            THEN 'order_payments'
        WHEN S.FILE_PATH LIKE '%/order_reviews.csv'
            THEN 'order_reviews'
    END AS DATASET_KEY
FROM RETAIL_DW.BRONZE.STAGE_FILE_LOG AS S
WHERE S.FILE_CATEGORY = 'DAILY'
  AND S.UPLOAD_STATUS = 'UPLOADED'
  AND NOT EXISTS (
      SELECT 1
      FROM RETAIL_DW.BRONZE.LOAD_AUDIT AS A
      WHERE A.FILE_PATH = S.FILE_PATH
        AND A.TARGET_TABLE = CASE
            WHEN S.FILE_PATH LIKE '%/orders.csv'
                THEN 'ORDERS'
            WHEN S.FILE_PATH LIKE '%/order_items.csv'
                THEN 'ORDER_ITEMS'
            WHEN S.FILE_PATH LIKE '%/order_payments.csv'
                THEN 'ORDER_PAYMENTS'
            WHEN S.FILE_PATH LIKE '%/order_reviews.csv'
                THEN 'ORDER_REVIEWS'
        END
        AND A.LOAD_STATUS IN (
            'SUCCESS',
            'PARTIAL_SUCCESS',
            'SKIPPED'
        )
  )
ORDER BY S.BATCH_ID, S.FILE_PATH;
