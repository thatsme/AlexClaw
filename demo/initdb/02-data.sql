-- The SQL demo's data, generated: the same at every start. One session, a
-- fixed seed, no parallel plans (which could change the order random() is
-- drawn in), every row drawn in id order. Dates run for two years up to a
-- fixed anchor, 2026-09-30, so "overdue" does not drift with the calendar.

SET max_parallel_workers_per_gather = 0;
SELECT setseed(0.42);

INSERT INTO regions (id, name)
VALUES (1, 'North'), (2, 'South'), (3, 'East'), (4, 'West'), (5, 'Central');

INSERT INTO customers (id, name, region_id, created_on)
SELECT g,
       (ARRAY['Alder', 'Birch', 'Cedar', 'Delta', 'Ember', 'Fjord', 'Granite', 'Harbor',
              'Iris', 'Juniper', 'Kestrel', 'Linden', 'Meridian', 'Nimbus', 'Orchard',
              'Pinnacle'])[1 + floor(random() * 16)::int]
         || ' '
         || (ARRAY['Trading', 'Supply', 'Foods', 'Logistics', 'Retail', 'Works',
                   'Partners', 'Market'])[1 + floor(random() * 8)::int]
         || ' #' || lpad(g::text, 3, '0'),
       1 + floor(random() * 5)::int,
       date '2024-10-01' + floor(random() * 365)::int
FROM generate_series(1, 300) AS g
ORDER BY g;

INSERT INTO products (id, name, category, unit_price)
SELECT g,
       (ARRAY['Classic', 'Premium', 'Eco', 'Compact', 'Pro', 'Family'])[1 + (g % 6)]
         || ' '
         || (ARRAY['Olive Oil', 'Pasta', 'Coffee', 'Rice', 'Tomatoes', 'Flour', 'Tea',
                   'Honey'])[1 + (g % 8)],
       (ARRAY['Pantry', 'Beverages', 'Fresh', 'Bakery'])[1 + (g % 4)],
       round((2 + random() * 48)::numeric, 2)
FROM generate_series(1, 40) AS g
ORDER BY g;

INSERT INTO orders (id, customer_id, ordered_at)
SELECT g,
       1 + floor(random() * 300)::int,
       date '2024-10-01' + floor(random() * 730)::int
FROM generate_series(1, 3000) AS g
ORDER BY g;

INSERT INTO order_lines (order_id, line, product_id, quantity, unit_price)
SELECT o.id, l, p.id, q, p.unit_price
FROM orders AS o
CROSS JOIN LATERAL generate_series(1, 1 + (o.id % 4)) AS l
CROSS JOIN LATERAL (SELECT 1 + floor(random() * 40)::int AS pid, 1 + floor(random() * 20)::int AS q
                    WHERE l > 0) AS r
JOIN products AS p ON p.id = r.pid
ORDER BY o.id, l;

-- An invoice per order, due in 30 days. Most are paid, some late; those not
-- paid by the anchor date and past due are the overdue ones.
INSERT INTO invoices (id, order_id, issued_on, due_on, amount, paid_on)
SELECT o.id,
       o.id,
       o.ordered_at,
       o.ordered_at + 30,
       (SELECT sum(quantity * unit_price) FROM order_lines WHERE order_id = o.id),
       CASE
         WHEN random() < 0.93 THEN least(o.ordered_at + floor(random() * 50)::int, date '2026-09-30')
         ELSE NULL
       END
FROM orders AS o
ORDER BY o.id;

-- An invoice cannot be paid after the anchor: one paid "in the future" is unpaid.
UPDATE invoices SET paid_on = NULL WHERE paid_on > date '2026-09-30';

ANALYZE;
