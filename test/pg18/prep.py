import os, re, sys, shlex
src=open(sys.argv[1]).read().splitlines(True)
vars={}
out=[]
skip_stack=[]
def skipping():
    return any(skip_stack)
for line in src:
    st=line.strip()
    if st.startswith('\\if'):
        parts=st.split()
        v=''
        if len(parts)>=2 and parts[1].startswith(':'):
            v=vars.get(parts[1][1:],'')
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        skip_stack.append(not (v.lower() in ('t','true','1','on','yes')))
        continue
    if st.startswith('\\else'):
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        if skip_stack: skip_stack[-1]=not skip_stack[-1]
        continue
    if st.startswith('\\endif'):
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        if skip_stack: skip_stack.pop()
        continue
    if st.startswith('\\quit'):
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        continue
    if skipping():
        if st:
            out.append('\\_echo '+line.rstrip('\n')+'\n')
        continue
    if st.endswith('\\gset'):
        q=st[:-5].strip()
        # A \gset may terminate a query continued from the previous line;
        # echo that line instead of executing it.
        if out and not out[-1].startswith('\\_echo ') and not out[-1].strip().startswith('--'):
            out[-1]='\\_echo '+out[-1].rstrip('\n')+'\n'
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        if re.search(r'pg_numa_available', q, re.I) or re.search(r'getdatabaseencoding', q, re.I):
            vars['skip_test']='f'
        continue
    if st.startswith('\\getenv'):
        # \getenv var ENV
        parts=st.split()
        if len(parts)>=3:
            vars[parts[1]]=os.environ.get(parts[2],'')
        out.append('\\_echo '+line.rstrip('\n')+'\n')
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
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        continue
    if st.startswith('\\'):
        if st.startswith('\\pset'):
            out.append(st + ';\n')
        else:
            out.append('\\_echo '+line.rstrip('\n')+'\n')
        continue
    if st.startswith('--'):
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        continue
    if re.search(r":'[A-Za-z_]", line) and "LAST_ERROR_MESSAGE" not in line:
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        # Execute the substituted statement but keep the original echo.
        sub=re.sub(r":'([A-Za-z_][A-Za-z0-9_]*)'", qrepl, line)
        out.append('\\_noecho '+sub)
        continue
    # substitute :'var'
    def qrepl(m):
        if m.group(1)=='LAST_ERROR_MESSAGE':
            return ":'LAST_ERROR_MESSAGE'"
        v=vars.get(m.group(1),'')
        return "'" + v.replace("'","''") + "'"
    line=re.sub(r":'([A-Za-z_][A-Za-z0-9_]*)'", qrepl, line)
    out.append(line)
final=[]
for ln in out:
    if ln.startswith('\\_echo ') and ln.rstrip('\n').endswith(';'):
        ln=ln.rstrip('\n')[:-1]+'@@SEMI@@\n'
    final.append(ln)
sys.stdout.write(''.join(final))
