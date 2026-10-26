#!/bin/sh
# Passes when the tests pass, the slice bug is gone and the tests weren't edited.
python3 -c "import tests.test_cart as t; t.test_total(); t.test_discount()" || exit 1
! grep -q "prices\[1:\]" shop/cart.py || exit 1
grep -q "assert total(\[10.0, 5.5, 4.5\]) == 20.0" tests/test_cart.py && grep -q "assert total(\[100.0\], 15) == 85.0" tests/test_cart.py
