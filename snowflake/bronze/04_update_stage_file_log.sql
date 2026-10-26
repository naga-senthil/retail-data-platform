
USE DATABASE RETAIL_DW;
USE SCHEMA BRONZE;

MERGE INTO STAGE_FILE_LOG AS target
USING (
    SELECT
        column1::VARCHAR AS FILE_PATH,
        column2::VARCHAR AS FILE_NAME,
        column3::VARCHAR AS BATCH_ID,
        column4::VARCHAR AS FILE_CATEGORY
    FROM VALUES
        ('daily/batch_20160904/orders.csv',
         'orders.csv', '20160904', 'TRANSACTIONAL'),
        ('daily/batch_20160904/order_items.csv',
         'order_items.csv', '20160904', 'TRANSACTIONAL'),
        ('daily/batch_20160904/order_payments.csv',
         'order_payments.csv', '20160904', 'TRANSACTIONAL'),
        ('daily/batch_20160904/order_reviews.csv',
         'order_reviews.csv', '20160904', 'TRANSACTIONAL'),
        ('reference/customers.csv',
         'customers.csv', 'REFERENCE', 'REFERENCE'),
        ('reference/products.csv',
         'products.csv', 'REFERENCE', 'REFERENCE'),
        ('reference/sellers.csv',
         'sellers.csv', 'REFERENCE', 'REFERENCE'),
        ('reference/geolocation.csv',
         'geolocation.csv', 'REFERENCE', 'REFERENCE'),
        ('reference/category_translation.csv',
         'category_translation.csv', 'REFERENCE', 'REFERENCE')
) AS source
ON target.FILE_PATH = source.FILE_PATH

WHEN MATCHED THEN UPDATE SET
    target.FILE_NAME = source.FILE_NAME,
    target.BATCH_ID = source.BATCH_ID,
    target.FILE_CATEGORY = source.FILE_CATEGORY,
    target.UPLOAD_STATUS = 'UPLOADED',
    target.UPLOADED_AT = COALESCE(
        target.UPLOADED_AT, CURRENT_TIMESTAMP()
    ),
    target.LAST_CHECKED_AT = CURRENT_TIMESTAMP(),
    target.ERROR_MESSAGE = NULL

WHEN NOT MATCHED THEN INSERT (
    FILE_PATH,
    FILE_NAME,
    BATCH_ID,
    FILE_CATEGORY,
    UPLOAD_STATUS,
    DISCOVERED_AT,
    UPLOADED_AT,
    LAST_CHECKED_AT
)
VALUES (
    source.FILE_PATH,
    source.FILE_NAME,
    source.BATCH_ID,
    source.FILE_CATEGORY,
    'UPLOADED',
    CURRENT_TIMESTAMP(),
    CURRENT_TIMESTAMP(),
    CURRENT_TIMESTAMP()
);
