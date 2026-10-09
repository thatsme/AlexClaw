-- The SQL demo's schema: a small fictional wholesaler. Every name and number
-- in it is generated (02-data.sql); none is real.

CREATE TABLE regions (
  id   integer PRIMARY KEY,
  name text NOT NULL UNIQUE
);

CREATE TABLE customers (
  id         integer PRIMARY KEY,
  name       text NOT NULL,
  region_id  integer NOT NULL REFERENCES regions (id),
  created_on date NOT NULL
);

CREATE TABLE products (
  id         integer PRIMARY KEY,
  name       text NOT NULL,
  category   text NOT NULL,
  unit_price numeric(10, 2) NOT NULL
);

CREATE TABLE orders (
  id          integer PRIMARY KEY,
  customer_id integer NOT NULL REFERENCES customers (id),
  ordered_at  date NOT NULL
);

CREATE TABLE order_lines (
  order_id   integer NOT NULL REFERENCES orders (id),
  line       integer NOT NULL,
  product_id integer NOT NULL REFERENCES products (id),
  quantity   integer NOT NULL,
  unit_price numeric(10, 2) NOT NULL,
  PRIMARY KEY (order_id, line)
);

CREATE TABLE invoices (
  id        integer PRIMARY KEY,
  order_id  integer NOT NULL UNIQUE REFERENCES orders (id),
  issued_on date NOT NULL,
  due_on    date NOT NULL,
  amount    numeric(12, 2) NOT NULL,
  paid_on   date
);

CREATE INDEX orders_ordered_at ON orders (ordered_at);
CREATE INDEX invoices_unpaid_due ON invoices (due_on) WHERE paid_on IS NULL;
