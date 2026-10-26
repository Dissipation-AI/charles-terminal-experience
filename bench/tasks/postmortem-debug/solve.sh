python3 -c "
import sys, runpy
try:
    runpy.run_path('etl.py', run_name='__main__')
except ZeroDivisionError:
    tb = sys.exc_info()[2]
    while tb:
        if tb.tb_frame.f_code.co_name == 'normalise': f = tb.tb_frame
        tb = tb.tb_next
    open('answer.txt', 'w').write(f\"{f.f_locals['rec']['id']} {f.f_locals['weight']}\n\")" > /dev/null
