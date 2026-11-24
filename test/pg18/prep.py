import os, re, sys, shlex
src=open(sys.argv[1]).read().splitlines(True)
vars={}
out=[]
for line in src:
    st=line.strip()
    if st.startswith('\\getenv'):
        # \getenv var ENV
        parts=st.split()
        if len(parts)>=3:
            vars[parts[1]]=os.environ.get(parts[2],'')
        continue
    if st.startswith('\\set'):
        # Parse psql-style tokens; expand :var, strip quotes.
        rest=st[4:].strip()
        try:
            toks=shlex.split(rest, posix=True)
        except ValueError:
            toks=rest.split()
        if toks:
            name=toks[0]; val=''
            for t in toks[1:]:
                if t.startswith(':'):
                    val += vars.get(t[1:],'')
                else:
                    val += t
            vars[name]=val
        continue
    if st.startswith('\\'):
        if st.startswith('\\pset'):
            out.append(st + ';\n')
        continue
    # substitute :'var'
    def qrepl(m):
        v=vars.get(m.group(1),'')
        return "'" + v.replace("'","''") + "'"
    line=re.sub(r":'([A-Za-z_][A-Za-z0-9_]*)'", qrepl, line)
    out.append(line)
sys.stdout.write(''.join(out))
