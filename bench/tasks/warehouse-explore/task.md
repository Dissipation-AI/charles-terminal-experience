`warehouse.load()` (in `warehouse.py`) pulls a snapshot of our store's data; it's slow, and every call returns a newer snapshot. From one snapshot, answer:

1. Which region has the most gold-tier customers?
2. In that region, the total refunded amount, in cents, on orders placed by gold-tier customers.
3. The id of the customer with the most cancelled orders.

Write one line to `answer.txt`: `<snapshot id> <region> <cents> <customer id>`.
