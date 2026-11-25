import os, re, sys, shlex
src=open(sys.argv[1]).read().splitlines(True)
vars={}
out=[]
skip_stack=[]
copyin_remaining=0
def skipping():
    return any(skip_stack)
def split_multicmd(text):
    parts=[]; cur=''; q=None; i=0
    while i < len(text):
        ch=text[i]
        if q:
            cur+=ch
            if ch==q: q=None
            i+=1; continue
        if ch in ("'",'"'):
            q=ch; cur+=ch; i+=1; continue
        if ch=='\\' and i+1<len(text) and text[i+1]==';':
            parts.append(cur); cur=''; i+=2; continue
        cur+=ch; i+=1
    parts.append(cur)
    return parts
for line in src:
    st=line.strip()
    if copyin_remaining>0:
        if st=='\\.':
            out.append('\\_copyin_end;\n')
            copyin_remaining-=1
        elif st:
            out.append('\\_copyin '+line.rstrip('\n').replace(';','@@SEMI@@')+';\n')
        continue
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
        # A \gset may terminate a query continued from the previous line(s);
        # fold that SQL into the query and echo the line instead of running it.
        if out and not out[-1].startswith('\\_echo ') and not out[-1].strip().startswith('--') and not out[-1].rstrip().endswith(';'):
            prev=out[-1].rstrip('\n')
            out[-1]='\\_echo '+prev+'\n'
            q=prev.strip()+' '+q
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        if re.search(r'pg_numa_available', q, re.I) or re.search(r'getdatabaseencoding', q, re.I):
            vars['skip_test']='f'
        # Let the psql harness execute the query silently and bind the
        # first row's columns as psql variables.
        qq=q.rstrip().rstrip(';')
        out.append('\\_gset '+qq+'@@SEMI@@\n')
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
    if st.startswith('\\copy '):
        out.append('\\_echo '+line.rstrip('\n')+'\n')
        cmd=line.strip()[1:]
        if not cmd.rstrip().endswith(';'): cmd=cmd.rstrip()+';'
        out.append('\\_noecho '+cmd+'\n')
        continue
    if '\\;' in line and not st.startswith('--'):
        parts=split_multicmd(line.rstrip('\n'))
        # The first element is the leading SQL text; separators follow.
        cmds=[]
        for p in parts:
            p=p.split('--',1)[0].strip()
            if not p: continue
            if not p.endswith(';'): p+=';'
            cmds.append(p)
        esc=line.rstrip('\n').replace(';','@@SEMI@@')
        out.append('\\_echo '+esc+'\n')
        out.append('\\_line_begin;\n')
        for cmd in cmds:
            out.append('\\_noecho '+cmd+'\n')
            if re.match(r'(?i)copy\s+[^\s(]', cmd) and 'from stdin' in cmd.lower():
                copyin_remaining+=1
        out.append('\\_line_end;\n')
        continue
    if st.startswith('\\') and st=='\\.':
        continue
    if st.startswith('\\'):
        if st.startswith('\\pset'):
            out.append(st + ';\n')
        elif st.startswith('\\c'):
            out.append('\\_echo '+line.rstrip('\n')+'\n')
            out.append('\\_noecho \\c;\n')
        elif st.startswith('\\d ') or st.startswith('\\da') or st.startswith('\\df') or st.startswith('\\dv') or st.startswith('\\di'):
            out.append('\\_echo '+line.rstrip('\n')+'\n')
            cmd=line.rstrip('\n')
            if not cmd.endswith(';'): cmd+=';'
            out.append('\\_noecho '+cmd+'\n')
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
        if m.group(1)=='DBNAME':
            return "'postgres'"
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
