"""Regenerate Blowfish pi constants with Python standard-library Decimal."""
from decimal import Decimal, localcontext
# Blowfish P/S initialization: fractional hexadecimal digits of pi, FIPS convention.
with localcontext() as ctx:
    ctx.prec=10200
    m=1;l=13591409;x=1;k=6;s=Decimal(l)
    for i in range(1,730):
        m=m*(k*k*k-16*k)//(i*i*i);l+=545140134;x*=-262537412640768000;s+=Decimal(m*l)/x;k+=12
    pi=426880*Decimal(10005).sqrt()/s
    value=int((pi-3)*Decimal(16)**(1042*8))
    digits=f'{value:0{1042*8}x}'
assert digits.startswith('243f6a8885a308d313198a2e03707344')
words=[digits[i:i+8] for i in range(0,len(digits),8)]
with open('native/ssh/ssh_blowfish_constants.inc','w') as f:
    f.write('// Blowfish initialization: first 8336 hexadecimal fractional digits of pi.\n// Generated with the Chudnovsky series, no external implementation or library.\nconstexpr uint32_t blowfish_initial[1042] = {\n')
    for i in range(0,len(words),6):f.write('  '+','.join('0x'+w for w in words[i:i+6])+',\n')
    f.write('};\n')
