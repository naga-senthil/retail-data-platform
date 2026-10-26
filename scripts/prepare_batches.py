
import argparse
import csv
import shutil
from datetime import date, datetime, timedelta
from pathlib import Path

FIRST_DATE = date(2016, 9, 4)
LAST_DATE = date(2018, 10, 17)

TRANSACTIONAL = {
    "olist_orders_dataset.csv": "orders.csv",
    "olist_order_items_dataset.csv": "order_items.csv",
    "olist_order_payments_dataset.csv": "order_payments.csv",
    "olist_order_reviews_dataset.csv": "order_reviews.csv",
}

REFERENCE = {
    "olist_customers_dataset.csv": "customers.csv",
    "olist_products_dataset.csv": "products.csv",
    "olist_sellers_dataset.csv": "sellers.csv",
    "product_category_name_translation.csv": "category_translation.csv",
    "olist_geolocation_dataset.csv": "geolocation.csv",
}


def read_csv(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        return reader.fieldnames, list(reader)


def write_csv(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def prepare_reference(raw, output):
    ref_dir = output / "reference"
    ref_dir.mkdir(parents=True, exist_ok=True)
    manifest = []

    for source, target_name in REFERENCE.items():
        src = raw / source
        target = ref_dir / target_name

        if not src.is_file():
            raise FileNotFoundError(f"Missing source file: {src}")

        if not target.exists():
            shutil.copy2(src, target)

        header, rows = read_csv(target)
        manifest.append({
            "source_file": source,
            "output_file": target_name,
            "data_rows": len(rows),
        })
        print(f"Reference ready: {target_name} ({len(rows):,} rows)")

    write_csv(
        ref_dir / "manifest.csv",
        ["source_file", "output_file", "data_rows"],
        manifest,
    )


def prepare_batch(start, days, raw, output):
    end = start + timedelta(days=days)
    batch_id = start.strftime("%Y%m%d")
    folder = output / "daily" / f"batch_{batch_id}"

    if folder.exists():
        raise FileExistsError(f"Batch already exists: {folder}")

    # Read orders and determine which order IDs belong to this window.
    orders_header, orders = read_csv(raw / "olist_orders_dataset.csv")
    selected_orders = []
    order_ids = set()

    for row in orders:
        timestamp = row.get("order_purchase_timestamp", "")
        try:
            purchase_date = datetime.fromisoformat(timestamp).date()
        except (ValueError, TypeError):
            continue

        if start <= purchase_date < end:
            selected_orders.append(row)
            order_ids.add(row["order_id"])

    selected = {"orders.csv": (orders_header, selected_orders)}

    # Select child records belonging to orders in this batch.
    for source, output_name in list(TRANSACTIONAL.items())[1:]:
        header, rows = read_csv(raw / source)
        child_rows = [r for r in rows if r.get("order_id") in order_ids]
        selected[output_name] = (header, child_rows)

    folder.mkdir(parents=True)
    manifest = []

    for filename, (header, rows) in selected.items():
        write_csv(folder / filename, header, rows)
        manifest.append({
            "batch_id": batch_id,
            "start_date": start.isoformat(),
            "end_date": (end - timedelta(days=1)).isoformat(),
            "file_name": filename,
            "data_rows": len(rows),
        })
        print(f"  {filename}: {len(rows):,} rows")

    write_csv(
        folder / "manifest.csv",
        ["batch_id", "start_date", "end_date", "file_name", "data_rows"],
        manifest,
    )
    print(f"Generated {folder}")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--start", help="Batch start date YYYY-MM-DD")
    group.add_argument("--all", action="store_true")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--raw-dir", default="data/raw")
    parser.add_argument("--output-dir", default="data/batches")
    args = parser.parse_args()

    if args.days < 1:
        parser.error("--days must be positive")

    raw = Path(args.raw_dir)
    output = Path(args.output_dir)

    # Check required files before doing any preparation.
    for filename in list(TRANSACTIONAL) + list(REFERENCE):
        if not (raw / filename).is_file():
            raise FileNotFoundError(f"Missing required file: {raw / filename}")

    prepare_reference(raw, output)

    if args.all:
        current = FIRST_DATE
        while current <= LAST_DATE:
            prepare_batch(current, args.days, raw, output)
            current += timedelta(days=args.days)
    else:
        current = date.fromisoformat(args.start)
        if not FIRST_DATE <= current <= LAST_DATE:
            parser.error(f"Start date must be between {FIRST_DATE} and {LAST_DATE}")
        prepare_batch(current, args.days, raw, output)

    print("Preparation complete. No Snowflake operations performed.")


if __name__ == "__main__":
    main()
