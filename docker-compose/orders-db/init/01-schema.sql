-- Orders schema used by the incident-response demo.
-- checkout-service leaks connections under load; the readonly-orders Vault DB role
-- is scoped to SELECT only on this table, nothing else in the database.
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO orders (customer_id, status) VALUES
    ('cust-1001', 'completed'),
    ('cust-1002', 'completed'),
    ('cust-1003', 'pending');

-- Deliberately separate, higher-sensitivity table the ceiling policy must
-- keep the agent away from even if it (or a human approver) asks for it.
CREATE TABLE billing_accounts (
    id SERIAL PRIMARY KEY,
    customer_id TEXT NOT NULL,
    card_last4 TEXT NOT NULL,
    balance_cents BIGINT NOT NULL DEFAULT 0
);

INSERT INTO billing_accounts (customer_id, card_last4, balance_cents) VALUES
    ('cust-1001', '4242', 10000),
    ('cust-1002', '1881', 2500);
