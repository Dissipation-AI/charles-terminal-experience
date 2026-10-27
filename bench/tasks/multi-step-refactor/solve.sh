perl -pi -e 's/\bcalc\b/rectangle_area/g; s/calc\(/rectangle_area(/g; s/import calc/import rectangle_area/' lib/geometry.py lib/report.py && python3 check_all.py
