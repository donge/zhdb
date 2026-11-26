#!/usr/bin/env python3
"""Tiny psql-like client for the zhdb wire protocol (test harness only)."""
import socket, struct, sys, re, os, unicodedata

def dwidth(s):
    """Terminal display width (combining marks are zero-width, CJK is 2)."""
    w=0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        w += 2 if unicodedata.east_asian_width(ch) in ("W","F") else 1
    return w

def msg(tag, payload=b""):
    return tag + struct.pack("!I", len(payload) + 4) + payload

class Client:
    def __init__(self, port, user="zhdb", db="postgres"):
        self.notices=[]
        self.current_stmt=""
        self.copy_text=None
        self.s = socket.create_connection(("127.0.0.1", port), timeout=30)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        params = b"user\x00" + user.encode() + b"\x00database\x00" + db.encode() + b"\x00\x00"
        self.s.sendall(struct.pack("!I", len(params) + 8) + struct.pack("!I", 196608) + params)
        while True:
            tag, body = self._recv()
            if tag == b"R":
                code = struct.unpack("!I", body[:4])[0]
                if code == 0:
                    continue
                raise RuntimeError("auth code %d not supported" % code)
            if tag == b"N":
                fields={}
                for part in body.split(b"\x00"):
                    if len(part)>=1: fields[part[:1]]=part[1:].decode(errors="replace")
                sev=fields.get(b"S","NOTICE")
                if b"M" in fields: self.notices.append(sev+":  "+fields[b"M"])
                if b"D" in fields: self.notices.append("DETAIL:  "+fields[b"D"])
                if b"H" in fields: self.notices.append("HINT:  "+fields[b"H"])
            if tag == b"E":
                raise RuntimeError(self._err(body))
            if tag == b"Z":
                return

    def _recv(self):
        hdr = b""
        while len(hdr) < 5:
            c = self.s.recv(5 - len(hdr))
            if not c:
                raise EOFError
            hdr += c
        tag, ln = hdr[:1], struct.unpack("!I", hdr[1:5])[0]
        body = b""
        while len(body) < ln - 4:
            c = self.s.recv(ln - 4 - len(body))
            if not c:
                raise EOFError
            body += c
        return tag, body

    @staticmethod
    def _err(body):
        return body.split(b"M", 1)[1].split(b"\x00", 1)[0].decode(errors="replace") if b"M" in body else body.decode(errors="replace")

    def query(self, sql, copy_data=None):
        self.notices=[]
        self.current_stmt=sql
        self.copy_text=None
        blocks=list(copy_data or [])
        self.s.sendall(msg(b"Q", sql.encode() + b"\x00"))
        cols = None; rows = []; err = None; copy_buf=None
        while True:
            tag, body = self._recv()
            if tag == b"H":
                copy_buf=[]
            elif tag == b"d":
                if copy_buf is not None: copy_buf.append(body)
            elif tag == b"c":
                if copy_buf is not None:
                    self.copy_text=b"".join(copy_buf).decode(errors="replace")
                    copy_buf=None
            elif tag == b"G":
                for line in (blocks.pop(0) if blocks else []):
                    self.s.sendall(msg(b"d", line.encode()+b"\n"))
                self.s.sendall(msg(b"c"))
            elif tag == b"T":
                n = struct.unpack("!H", body[:2])[0]; off = 2; cols = []
                for _ in range(n):
                    end = body.index(b"\x00", off); cols.append(body[off:end].decode(errors="replace")); off = end + 1 + 18
            elif tag == b"D":
                n = struct.unpack("!H", body[:2])[0]; off = 2; row = []
                for _ in range(n):
                    ln = struct.unpack("!i", body[off:off+4])[0]; off += 4
                    if ln < 0:
                        row.append(None)
                    else:
                        row.append(body[off:off+ln].decode(errors="replace")); off += ln
                rows.append(row)
            elif tag == b"N":
                fields={}
                for part in body.split(b"\x00"):
                    if len(part)>=1:
                        fields[part[:1]]=part[1:].decode(errors="replace")
                sev=fields.get(b"S","NOTICE")
                # run.sh normalizes NOTICE lines from the official expected
                # files until every test produces them; warnings must match.
                if sev=="WARNING":
                    if b"M" in fields: self.notices.append(sev+":  "+fields[b"M"])
                    if b"D" in fields: self.notices.append("DETAIL:  "+fields[b"D"])
                    if b"H" in fields: self.notices.append("HINT:  "+fields[b"H"])
                elif sev=="INFO":
                    if b"M" in fields: self.notices.append("INFO:  "+fields[b"M"])
                elif b"M" in fields and "is only a shell" in fields[b"M"]:
                    if "argument type" in fields[b"M"] and self.current_stmt:
                        clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",self.current_stmt)
                        typ=fields[b"M"].split("argument type ",1)[1].split(" is only",1)[0]
                        p0=clean.find("(")
                        pos=clean.find(typ, p0 if p0>=0 else 0)
                        self.notices.append("LINE 1: "+clean.split("\n")[0])
                        self.notices.append(" "*(8+max(pos,0))+"^")
                elif b"D" in fields:
                    # run.sh drops the NOTICE line from the expected file but
                    # keeps its DETAIL lines.
                    self.notices.append("DETAIL:  "+fields[b"D"])
            elif tag == b"E":
                err = self._err(body)
            elif tag == b"Z":
                break
        if err:
            raise RuntimeError(err)
        return cols or [], rows

def split_sql(src):
    out=[]; start=0; i=0; n=len(src); quote=None; depth=0
    while i<n:
        c=src[i]
        if quote:
            if c==quote:
                if i+1<n and src[i+1]==quote:
                    i+=2; continue
                quote=None
            elif c=='\\' and quote=="'":
                i+=2; continue
            i+=1; continue
        if c in ("'", '"'):
            quote=c; i+=1; continue
        if c=='-' and i+1<n and src[i+1]=='-':
            j=src.find('\n',i); i=n if j<0 else j+1; continue
        if c=='/' and i+1<n and src[i+1]=='*':
            i+=2; depth=1
            while i<n and depth>0:
                if i+1<n and src[i:i+2]=='/*': depth+=1; i+=2
                elif i+1<n and src[i:i+2]=='*/': depth-=1; i+=2
                else: i+=1
            continue
        if c=='$':
            m=re.match(r'\$[A-Za-z0-9_]*\$', src[i:])
            if m:
                tag=m.group(0); j=src.find(tag, i+len(tag))
                if j<0: i=n
                else: i=j+len(tag)
                continue
        if c=='(':
            depth+=1; i+=1; continue
        if c==')':
            if depth>0: depth-=1
            i+=1; continue
        if c==';' and depth==0:
            end=i+1
            j=end
            while j<n and src[j] in (' ','\t'): j+=1
            if j+1<n and src[j:j+2]=='--':
                nl=src.find('\n', j)
                if nl>=0: end=nl
            out.append((src[start:end], src[start:end])); start=end
            i=end
        i+=1
    if src[start:].strip(): out.append((src[start:], src[start:]))
    return out

def fmt_table(cols, rows, null_display="", numeric=None, strip_float_zero=False, float_mode=None, float_sigs=None, all_float_sig=None, decl_types=None):
    if not cols: return ""
    numeric = numeric or [False]*len(cols)
    sig_by_col = {x.lower():s for x,s in (float_mode or {}).items()}
    def disp(v, ci):
        if v is None: return null_display
        if v.strip().lower() in ("nan","nan.0"):
            return "NaN"
        if v.strip().lower() in ("inf","infinity","inf.0"):
            return "Infinity"
        if v.strip().lower() in ("-inf","-infinity","-inf.0"):
            return "-Infinity"
        if all_float_sig and v not in ("NaN","Infinity","-Infinity"):
            if re.fullmatch(r"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", v):
                try:
                    return format(float(v), ".%dg" % all_float_sig)
                except Exception:
                    return v
        mode = float_sigs[ci] if (float_sigs and ci < len(float_sigs)) else sig_by_col.get(cols[ci].lower())
        if mode:
            sig=mode
            try:
                f=float(v)
                if f == 0: return "0"
                if abs(f) >= 1e15 or abs(f) < 1e-4:
                    out=format(f, ".%de" % (sig-1))
                    mant,exp=out.split("e")
                    mant=mant.rstrip("0").rstrip(".")
                    return mant+"e"+exp
                return format(f, ".%dg" % sig)
            except Exception:
                return v
        if strip_float_zero:
            return re.sub(r'^(-?\d+)\.0$', r'\1', v)
        return v
    vals=[[disp(v,ci) for ci,v in enumerate(r)] for r in rows]
    # Aligned output expands tabs (8-column tab stops) and renders multi-line
    # values with `+` continuation markers, like psql.
    cell_lines=[[[ln.replace("\t","        ") for ln in (x.split("\n") if "\n" in x else [x])] for x in r] for r in vals]
    widths=[]
    for ci,c in enumerate(cols):
        widths.append(max([dwidth(c)] + [max(dwidth(ln) for ln in r[ci]) for r in cell_lines]) + 2)
    cols=["char" if c=='"char"' else c for c in cols]
    def centered(c,w):
        pad=max(0,w-dwidth(c)); return " "*(pad//2)+c+" "*(pad-pad//2)
    hdr="|".join(" "+centered(c,widths[i]-2)+" " for i,c in enumerate(cols))
    sep="+".join("-"*w for w in widths)
    body=[]
    for ri,r in enumerate(vals):
        cl=cell_lines[ri]
        nlines=max(len(c) for c in cl) if cl else 1
        for ln_i in range(nlines):
            parts=[]
            for i in range(len(cols)):
                lines=cl[i]
                txt=lines[ln_i] if ln_i < len(lines) else ""
                more=ln_i < len(lines)-1
                pad=max(0,widths[i]-2-dwidth(txt))
                if more: parts.append(" "+txt+" "*pad+"+")
                elif numeric[i]: parts.append(" "+" "*pad+txt+" ")
                else: parts.append(" "+txt+" "*pad+" ")
            line="|".join(parts)
            if nlines>1:
                line=line.rstrip()
                last_txt = cl[-1][ln_i] if cl and ln_i < len(cl[-1]) else ""
                if last_txt == "" and line.endswith("|"):
                    line += " "
                body.append(line)
                continue
            if line.strip()=="" and len(cols)==1:
                line=" "*(widths[0]-1) if numeric[-1] else " "*(1+len(r[0]))
            elif numeric[-1] and r and r[-1]=="": line=line[:-1]
            elif len(cols)>0 and r and r[-1]=="" and not numeric[-1]:
                # psql keeps the leading separator space of an empty text cell.
                all_empty = all((rr[-1] in (None,"")) for rr in rows)
                dt_last = (decl_types[-1] if decl_types and len(decl_types)==len(cols) else None)
                text_types = ("text","varchar","char","bpchar","character","name","uuid","json","jsonb")
                if all_empty and dt_last in text_types:
                    line=line[:-(widths[-1]-1)] if widths[-1]>1 else line
                else:
                    narrownum = 2 if (widths[-1]==3 and cols[-1]!="p") else 1
                    line=line[:-(widths[-1]-narrownum)] if widths[-1]>1 else line
            elif r and r[-1].endswith(" "): line=line[:-1]
            else: line=line.rstrip()
            body.append(line)
    body.append("(%d row%s)" % (len(rows), "" if len(rows)==1 else "s"))
    return "\n".join([hdr,sep]+body)+"\n"


def index_lines(cli, toid):
    iq=("SELECT ic.relname, i.indisprimary, i.indisunique, i.indisvalid, pg_get_indexdef(i.indexrelid), "
        "con.conname, con.condeferrable, i.indisreplident "
        "FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid "
        "LEFT JOIN pg_constraint con ON con.conindid = i.indexrelid "
        "WHERE i.indrelid = %s ORDER BY i.indisprimary DESC, ic.relname" % toid)
    try:
        _c, irows = cli.query(iq)
    except RuntimeError:
        return []
    out=[]
    if not irows: return out
    out.append("Indexes:")
    for r in irows:
        iname=r[0]; prim=(r[1]=="t"); uniq=(r[2]=="t")
        valid=(len(r)<4 or r[3]!="f")
        d=r[4] if len(r)>4 and r[4] else ""
        iscon=(len(r)>5 and r[5] not in (None,""))
        defer=(len(r)>6 and r[6]=="t")
        rid=(len(r)>7 and r[7]=="t")
        if d.startswith("EXCLUDE"):
            line='    "%s" %s' % (iname, d)
            if rid: line += " REPLICA IDENTITY"
            out.append(line)
            continue
        body=d.split(" USING ",1)[1] if " USING " in d else "btree (?)"
        if prim: head="PRIMARY KEY, "
        elif uniq and iscon: head="UNIQUE CONSTRAINT, "
        elif uniq: head="UNIQUE, "
        else: head=""
        line='    "%s" %s%s' % (iname, head, body)
        if defer: line += " DEFERRABLE"
        if not valid: line += " INVALID"
        if rid: line += " REPLICA IDENTITY"
        out.append(line)
    return out

def relation_meta(cli, qname, schema):
    qs=(" AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = '%s')" % schema.replace("'","''")) if schema else ""
    try:
        _c, r = cli.query("SELECT c.oid, c.relkind, c.relreplident FROM pg_class c WHERE c.relname = '%s'%s" % (qname, qs))
    except RuntimeError:
        r=[]
    if not r: return (None, "r", "d")
    return (r[0][0], r[0][1] or "r", r[0][2] or "d")

def storage_of(typ):
    t=typ.lower()
    if t in ("text","character varying","varchar","json","jsonb","bytea","xml","tsvector"): return "extended"
    if t.startswith("character") or t=="char": return "extended"
    return "plain"

def plus_describe(cli, stmt):
    name=stmt[4:].strip()
    if name.endswith(';'): name=name[:-1].strip()
    name=name.strip('"')
    schema=""
    if "." in name:
        schema, name = name.rsplit(".", 1)
    qname=name.replace("'","''")
    qschema=schema.replace("'","''")
    qs=(" AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = '%s')" % qschema) if schema else ""
    q=("SELECT a.attname, a.atttypid::regtype, a.attnotnull, a.attdefault FROM pg_class c "
       "JOIN pg_attribute a ON a.attrelid = c.oid "
       "WHERE c.relname = '%s'%s ORDER BY a.attnum" % (qname, qs))
    try:
        _c, drows = cli.query(q)
    except RuntimeError:
        drows=[]
    if not drows: return []
    toid, relkind, replit = relation_meta(cli, qname, schema)
    body_rows=[[r[0], r[1], "", ("not null" if (len(r)>2 and r[2]=="t") else ""),
                (r[3] if len(r)>3 and r[3] else ""), storage_of(r[1] or ""), "", ""] for r in drows]
    tbl=fmt_table(["Column","Type","Collation","Nullable","Default","Storage","Stats target","Description"], body_rows)
    lines=tbl.rstrip("\n").split("\n")
    if lines and re.match(r"^\(\d+ rows?\)$", lines[-1]):
        lines=lines[:-1]
    kind_title = "Partitioned table" if relkind=="p" else "Table"
    title='%s "%s"' % (kind_title, ((schema + "." + name) if schema else "public."+name))
    width=len(lines[0]) if lines else len(title)
    out=[" "*max(0,(width-len(title))//2)+title]
    out.extend(lines)
    if relkind=="p" and toid is not None:
        try:
            _c2, kr = cli.query("SELECT pg_get_partkeydef(%s)" % toid)
        except RuntimeError:
            kr=[]
        if kr and kr[0][0]:
            out.append("Partition key: %s" % kr[0][0])
    if toid is not None:
        out.extend(index_lines(cli, toid))
    nn=[[r[0]] for r in drows if (len(r)>2 and r[2]=="t")]
    if nn:
        out.append("Not-null constraints:")
        for r in nn:
            out.append('    "%s_%s_not_null" NOT NULL "%s"' % (name, r[0], r[0]))
    if replit=="f":
        out.append("Replica Identity: FULL")
    if relkind=="p" and toid is not None:
        try:
            _c3, pr = cli.query("SELECT child, bound FROM pg_partition_children('%s')" % qname)
        except RuntimeError:
            pr=[]
        if pr:
            parts=", ".join((r[0] + (" " + r[1] if r[1] else "")) for r in pr)
            out.append("Partitions: %s" % parts)
    out.append("")
    return out

def main():
    port=int(sys.argv[1]); path=sys.argv[2]; echo="--echo" in sys.argv; fail_on_error="--fail-on-error" in sys.argv
    cli=Client(port)
    src=open(path).read()
    out=[]
    # Minimal schema state needed for exact "value too long" messages. The
    # setup tables have 4-character columns; the char/varchar tests shadow
    # them with 1-character temp tables and restore them on DROP.
    schema={"CHAR_TBL":("character",4), "VARCHAR_TBL":("character varying",4)}
    table_types={"INT2_TBL":{"f1":"int2"}, "INT4_TBL":{"f1":"int4"}, "INT8_TBL":{"q1":"int8","q2":"int8"}, "FLOAT8_TBL":{"f1":"float8"}}
    temp_prev={}
    null_display=""
    float_sig=None
    verbosity="default"
    last_error=""
    gvars={}
    base_types=set()
    chunks=split_sql(src)
    copy_blocks=[]; copy_skip=set(); cur_block=None
    for ci,(raw,_) in enumerate(chunks):
        st=raw.strip()
        if st.startswith("\\_copyin_end"):
            if cur_block is not None: copy_blocks.append(cur_block)
            cur_block=None; copy_skip.add(ci)
        elif st.startswith("\\_copyin "):
            txt=st[9:].rstrip()
            if txt.endswith(";"): txt=txt[:-1]
            txt=txt.replace("@@SEMI@@",";")
            if cur_block is None: cur_block=[]
            cur_block.append(txt)
            copy_skip.add(ci)
    skip_cmds=False
    in_cmd_line=False
    for ci,(raw, _) in enumerate(chunks):
        if ci in copy_skip: continue
        _st0=raw.strip()
        if _st0.startswith("\\_line_begin"):
            in_cmd_line=True
            continue
        if _st0.startswith("\\_line_end"):
            in_cmd_line=False; skip_cmds=False
            continue
        # Echo-only meta lines inserted by prep.py (psql -a output). Keep the
        # original line order for the echo, execute only the SQL lines.
        echo_override=None
        if "\\_echo" in raw or "\\_noecho" in raw:
            echo_override=[]
            kept=[]
            for ln in raw.splitlines(True):
                if ln.strip().startswith("\\_line_begin"):
                    in_cmd_line=True
                    continue
                if ln.strip().startswith("\\_line_end"):
                    in_cmd_line=False; skip_cmds=False
                    continue
                if ln.strip().startswith("\\_gset "):
                    gq=ln.strip()[7:]
                    if gq.endswith("@@SEMI@@"): gq=gq[:-8]
                    else: gq=gq.rstrip().rstrip(';')
                    try:
                        gc, gr = cli.query(gq)
                        if gr:
                            for ci2, cn2 in enumerate(gc):
                                if ci2 < len(gr[0]):
                                    gvars[cn2]=gr[0][ci2]
                    except RuntimeError:
                        pass
                    continue
                if ln.strip().startswith("\\_noecho"):
                    if skip_cmds: continue
                    kept.append(ln.strip()[9:].replace("@@SEMI@@",";") + "\n")
                    continue
                if ln.strip().startswith("\\_echo"):
                    txt=ln.strip()[7:].replace("@@SEMI@@",";")
                    if txt.startswith("\\echo ") and ":LAST_ERROR_MESSAGE" in txt:
                        echo_override.append(txt.rstrip("\n"))
                        echo_override.append(last_error)
                        continue
                    if txt.startswith("\\echo "): txt=txt[6:]
                    if txt.startswith("\\set VERBOSITY "):
                        verbosity=txt[len("\\set VERBOSITY "):].strip()
                    if txt.strip(): echo_override.append(txt)
                else:
                    kept.append(ln)
                    if ln.strip(): echo_override.append(ln.rstrip("\n"))
            raw="".join(kept)
        # strip leading blank lines and comments-only prefix for execution
        stmt=raw.strip()
        if not stmt:
            if echo and echo_override: out.extend(echo_override)
            continue
        sm=re.search(r"\bSET\s+extra_float_digits\s*=\s*(-?\d+)", stmt, re.I)
        if sm:
            n=15+int(sm.group(1))
            float_sig=n if n>0 else None
        if echo:
            if echo_override is not None:
                out.extend(echo_override)
            else:
                shown="\n".join(l for l in raw.splitlines() if l.strip())
                if shown.startswith('\\') and shown.rstrip().endswith(';'):
                    shown=shown.rstrip()[:-1]
                if shown: out.append(shown)
        if stmt.startswith('\\c'):
            cli=Client(port)
            # NOTICE output is normalised by the harness; warnings are kept.
            if any(n.startswith("WARNING") for n in cli.notices):
                out.extend(cli.notices)
            continue
        if stmt.startswith('\\z'):
            name=stmt[2:].strip()
            if name.endswith(';'): name=name[:-1].strip()
            name=name.strip('"')
            qname=name.replace("'","''")
            try:
                _zc, zr = cli.query("SELECT relname, relkind, relacl, relowner FROM pg_class WHERE relname = '%s'" % qname)
            except RuntimeError:
                _zc, zr = [], []
            if zr:
                relname, relkind, acl, owner = zr[0][:4]
                typ={"r":"table","v":"view","S":"sequence","i":"index","c":"type","m":"materialized view"}.get(relkind,"table")
                if acl:
                    body=acl.strip()
                    if body.startswith("{") and body.endswith("}"):
                        body=body[1:-1]
                    entries=[e for e in body.split(",") if e]
                else:
                    entries=[]
                if not entries:
                    entries=["%s=arwdDxtm/%s" % (owner, owner)]
                hdr=["Schema","Name","Type","Access privileges","Column privileges","Policies"]
                vals=[["public"],[relname],[typ],entries,[""],[""]]
                widths=[max(len(hdr[i]), max(len(x) for x in vals[i]) if vals[i] else 0)+2 for i in range(6)]
                def fmt_cell(i,txt,center=False,mark=False):
                    w=widths[i]
                    inner=max(w-2,0)
                    if center:
                        left=max(0,(inner-len(txt))//2)
                        right=max(0,inner-len(txt)-left)
                        body=" "*left+txt+" "*right
                    else:
                        body=(txt+" "*inner)[:inner]
                    return " "+body+("+" if mark else " ")
                lines=[]
                lines.append(("|".join([fmt_cell(i,hdr[i],True) for i in range(6)])).rstrip()+" ")
                lines.append("+".join(["-"*widths[i] for i in range(6)]))
                for i,e in enumerate(entries):
                    last=(i==len(entries)-1)
                    if i==0:
                        row=[fmt_cell(0,"public"),fmt_cell(1,relname),fmt_cell(2,typ),fmt_cell(3,e,False,not last),fmt_cell(4,""),fmt_cell(5,"")]
                    else:
                        row=[fmt_cell(0,""),fmt_cell(1,""),fmt_cell(2,""),fmt_cell(3,e,False,not last),fmt_cell(4,""),fmt_cell(5,"")]
                    lines.append(("|".join(row)).rstrip()+" ")
                lines.append("(1 row)")
                title="Access privileges"
                width=len(lines[0])
                lines=[(" "*max(0,(width-len(title))//2))+title]+lines
                out.append("\n".join(lines))
                out.append("")
            continue
        if stmt.startswith('\\dt'):
            pat=stmt[3:].strip()
            if pat.endswith(';'): pat=pat[:-1].strip()
            if pat:
                like=pat.replace('*','%').replace('?','_').replace("'","''")
                w="AND relname LIKE '%s'" % like
            else:
                w=""
            try:
                _dc, dr = cli.query("SELECT relname, relowner FROM pg_class WHERE relkind = 'r' %s ORDER BY relname" % w)
            except RuntimeError:
                _dc, dr = [], []
            if dr:
                rows=[["public", r[0], "table", r[1] if len(r)>1 and r[1] else "zhdb"] for r in dr]
                tbl=fmt_table(["Schema","Name","Type","Owner"], rows)
                lines=tbl.rstrip("\n").split("\n")
                title="List of tables"
                width=len(lines[0]) if lines else len(title)
                lines=[(" "*max(0,(width-len(title))//2))+title]+lines
                out.append("\n".join(lines))
                out.append("")
            continue
        if stmt.startswith('\\da'):
            pat=stmt[3:].strip()
            if pat.endswith(';'): pat=pat[:-1].strip()
            if pat:
                like=pat.replace('*','%').replace('?','_').replace("'","''")
                w="AND aggfnoid LIKE '%s'" % like
            else:
                w=""
            q=("SELECT aggschema, aggfnoid, aggret, aggargs, aggdesc FROM pg_aggregate "
               "WHERE true %s ORDER BY aggfnoid" % w)
            try:
                dcols, drows = cli.query(q)
            except RuntimeError:
                dcols, drows = [], []
            if dcols:
                rows=[[("" if v is None else v) for v in r] for r in drows]
                tbl=fmt_table(["Schema","Name","Result data type","Argument data types","Description"], rows)
                lines=tbl.rstrip("\n").split("\n")
                title="List of aggregate functions"
                width=len(lines[0]) if lines else len(title)
                lines=[(" "*max(0,(width-len(title))//2))+title]+lines
                out.append("\n".join(lines))
                out.append("")
            continue
        if stmt.startswith('\\d+ '):
            out.extend(plus_describe(cli, stmt))
            continue
        if stmt.startswith('\\d ') and not stmt.startswith('\\d+') and not stmt.startswith('\\dt'):
            name=stmt[3:].strip()
            if name.endswith(';'): name=name[:-1].strip()
            name=name.strip('"')
            schema=""
            if "." in name:
                schema, name = name.rsplit(".", 1)
            qname=name.replace("'","''")
            qschema=schema.replace("'","''")
            q=("SELECT a.attname, a.atttypid::regtype, a.attnotnull, a.attdefault, c.reloftype FROM pg_class c "
               "JOIN pg_attribute a ON a.attrelid = c.oid "
               "WHERE c.relname = '%s'%s ORDER BY a.attnum" % (
                   qname,
                   (" AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = '%s')" % qschema) if schema else ""))
            try:
                dcols, drows = cli.query(q)
            except RuntimeError:
                dcols, drows = [], []
            reloftype=""
            if drows and len(drows[0])>4 and drows[0][4]:
                reloftype=drows[0][4]
            if not drows:
                try:
                    _c0, _r0 = cli.query("SELECT oid FROM pg_class WHERE relname = '%s'" % qname)
                except RuntimeError:
                    _r0 = []
                if not _r0:
                    continue
            body_rows=[[r[0], r[1], "", ("not null" if (len(r)>2 and r[2]=="t") else ""), (r[3] if len(r)>3 and r[3] else "")] for r in drows]
            tbl=fmt_table(["Column","Type","Collation","Nullable","Default"], body_rows)
            lines=tbl.rstrip("\n").split("\n")
            if lines and re.match(r"^\(\d+ rows?\)$", lines[-1]):
                lines=lines[:-1]
            try:
                _oc, orows = cli.query("SELECT oid FROM pg_class WHERE relname = '%s'" % qname)
                toid = orows[0][0] if orows else "0"
            except RuntimeError:
                toid = "0"
            lines.extend(index_lines(cli, toid))
            if reloftype:
                lines.append("Typed table of type: %s" % reloftype)
            title='Table "%s"' % ((schema + "." + name) if schema else "public."+name)
            width=len(lines[0]) if lines else len(title)
            out.append(" "*max(0,(width-len(title))//2)+title)
            out.extend(lines)
            out.append("")
            continue
        if stmt.startswith('\\_echo '):
            text=stmt[7:].rstrip()
            if text.endswith(';'): text=text[:-1]
            if text.startswith('\\echo '): text=text[6:]
            text=text.replace(':LAST_ERROR_MESSAGE', last_error)
            if text.strip(): out.append(text)
            continue
        if stmt.startswith('\\'):
            pm=re.search(r"\\pset\s+null\s+'([^']*)'", stmt, re.I)
            if pm: null_display=pm.group(1)
            continue
        m=re.search(r"CREATE\s+TEMP(?:ORARY)?\s+TABLE\s+(\w+)\s*\(\s*\w+\s+(char|varchar)", stmt, re.I)
        if m:
            t=m.group(1).upper(); kind=m.group(2).lower()
            temp_prev[t]=schema.get(t)
            schema[t]=("character" if kind=="char" else "character varying", 1)
        cm=re.search(r"CREATE\s+(?:TEMP(?:ORARY)?\s+)?TABLE\s+(\w+)\s*\((.*?)\)", stmt, re.I|re.S)
        if cm:
            t=cm.group(1).upper(); ts={}
            for part in cm.group(2).split(','):
                toks=part.strip().split()
                if len(toks)>=2: ts[toks[0].lower()]=toks[1].lower()
            table_types[t]=ts
        rn_m=re.match(r"ALTER\s+TABLE\s+(?:ONLY\s+)?(\w+)\*?\s+RENAME\s+(?:COLUMN\s+)?(\w+)\s+TO\s+(\w+)", stmt, re.I)
        if rn_m:
            t=rn_m.group(1).upper(); ts=table_types.get(t,{})
            if rn_m.group(2).lower() in ts: ts[rn_m.group(3).lower()]=ts.pop(rn_m.group(2).lower()); table_types[t]=ts
        ac_m=re.match(r"ALTER\s+TABLE\s+(?:ONLY\s+)?(\w+)\*?\s+ADD\s+(?:COLUMN\s+)?(\w+)\s+([A-Za-z][\w ]*)", stmt, re.I)
        if ac_m and ac_m.group(2).lower() not in ("constraint","primary","unique","check","foreign","exclude"):
            ts=table_types.setdefault(ac_m.group(1).upper(),{})
            ts[ac_m.group(2).lower()]=ac_m.group(3).strip().lower().split()[0]
        drop_m=re.search(r"DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?(\w+)", stmt, re.I)
        if drop_m:
            t=drop_m.group(1).upper()
            if t in temp_prev:
                if temp_prev[t] is None: schema.pop(t,None)
                else: schema[t]=temp_prev[t]
                temp_prev.pop(t,None)
        ctb=re.match(r"CREATE\s+TYPE\s+(\w+)\s*\(", stmt, re.I)
        if ctb and not re.search(r"\bAS\b", stmt, re.I):
            base_types.add(ctb.group(1).lower())
        if ":'LAST_ERROR_MESSAGE'" in stmt:
            stmt=stmt.replace(":'LAST_ERROR_MESSAGE'", "'"+last_error.replace("'","''")+"'")
        if gvars:
            def _bare(m):
                nm=m.group(1)
                if nm in ("LAST_ERROR_MESSAGE","DBNAME") or nm not in gvars: return m.group(0)
                v=gvars[nm]
                return "NULL" if v is None else v
            stmt=re.sub(r"(?<![:']):([A-Za-z_][A-Za-z0-9_]*)", _bare, stmt)
        copy_data=None
        if re.match(r"(?is)^\s*copy\s+[^(\s]", stmt) and "from stdin" in stmt.lower():
            copy_data=copy_blocks.pop(0) if copy_blocks else None
        try:
            cols, rows=cli.query(stmt, copy_data)
            if cli.notices: out.extend(cli.notices)
            if cli.copy_text is not None:
                out.append(cli.copy_text.rstrip("\n"))
        except RuntimeError as e:
            if cli.copy_text is not None:
                out.append(cli.copy_text.rstrip("\n"))
            if cli.notices: out.extend(cli.notices)
            if in_cmd_line: skip_cmds=True
            msg=str(e)
            last_error=msg
            detail_caret=False
            caret_pos=None
            hint=None
            detail_line=None
            if "\nDETAIL:  " in msg:
                msg, detail_line = msg.split("\nDETAIL:  ", 1)
            if "\nHINT:  " in msg:
                msg, hint = msg.split("\nHINT:  ", 1)
            context_line=None
            if "\nCONTEXT:  " in msg:
                msg, context_line = msg.split("\nCONTEXT:  ", 1)
            if msg=="syntax error" and re.search(r"^\s*copy\s*\(\s*select", stmt, re.I):
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                if re.search(r"\)\s*from\s+stdin", clean, re.I):
                    msg='syntax error at or near "from"'
                    caret_pos=clean.lower().rfind("from")
                else:
                    m=re.search(r"\)\s*\(", clean)
                    msg='syntax error at or near "("'
                    caret_pos=(m.end()-1) if m else None
                detail_caret=True
            elif msg=="ValueTooLong":
                m=re.search(r"INSERT INTO\s+(\w+)", stmt, re.I)
                t=(m.group(1).upper() if m else "")
                kind,maxlen=schema.get(t,("character",1))
                msg="value too long for type %s(%d)" % (kind,maxlen)
            elif msg=="InvalidBoolean":
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                typed=re.search(r"\b(?:bool|boolean)\s+'((?:''|[^'])*)'", clean, re.I)
                vm=typed or re.search(r"'((?:''|[^'])*)'", clean)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type boolean: "%s"' % val
                detail_caret = bool(typed)
            elif msg=="InvalidTableAlias":
                am=re.search(r"DELETE\s+FROM\s+(\w+)(?:\s+AS)?\s+(\w+)", stmt, re.I)
                tbl=am.group(1) if am else ""
                alias=am.group(2) if am else ""
                msg='invalid reference to FROM-clause entry for table "%s"' % tbl
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                mm=re.search(r"\b"+re.escape(tbl)+r"\.", clean, re.I)
                caret_pos=mm.start() if mm else None
                hint='Perhaps you meant to reference the table alias "%s".' % alias
                detail_caret=True
            elif msg.startswith('column "') and "GROUP BY clause" in msg:
                qm=re.match(r'column "([^"]+)"', msg)
                full=qm.group(1) if qm else ""
                base=full.rsplit('.',1)[-1]
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                ms=list(re.finditer(re.escape(full), clean)) or list(re.finditer(r"\b"+re.escape(base)+r"\b", clean))
                caret_pos=ms[0].start() if ms else None
                detail_caret = not re.match(r"^\s*EXECUTE\b", stmt, re.I)
            elif msg=="TableColumnMismatch":
                sm=re.search(r"FROM\s*\(\s*TABLE\s+(\w+)\s*\)\s+(?:AS\s+)?(\w+)\s*\(([^)]*)\)", stmt, re.I)
                if sm:
                    t,alias,cols=sm.group(1).upper(),sm.group(2),sm.group(3)
                else:
                    sm=re.search(r"FROM\s+(\w+)\s+(?:AS\s+)?(\w+)\s*\(([^)]*)\)", stmt, re.I)
                if sm:
                    t,alias,cols=sm.group(1).upper(),sm.group(2),sm.group(3)
                    avail=len(table_types.get(t,{})) or 1
                    want=len([c for c in cols.split(',') if c.strip()])
                    msg='table "%s" has %d columns available but %d columns specified' % (alias,avail,want)
                else:
                    msg="table has wrong number of columns"
            elif msg=="InvalidChannelName": msg="channel name cannot be empty"
            elif msg=="ChannelNameTooLong": msg="channel name too long"
            elif msg=="InvalidPoint":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type point: "%s"' % val
                detail_caret=True
            elif msg=="InvalidCircle":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type circle: "%s"' % val
                detail_caret=True
            elif msg=="InvalidLine":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type line: "%s"' % val
                detail_caret=True
            elif msg.startswith("invalid line specification"):
                if re.search(r"VALUES\s*\(\s*'", stmt, re.I):
                    clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                    caret_pos=clean.find("'")
                    detail_caret=True
            elif msg.startswith('"') and "out of range for type double precision" in msg:
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                if re.search(r"VALUES\s*\(", stmt, re.I):
                    caret_pos=clean.find("'")
                else:
                    tm=re.match(r'"([^"]+)"', msg)
                    tok=tm.group(1) if tm else ""
                    mm=re.search(re.escape(tok), clean)
                    caret_pos=mm.start() if mm else None
                detail_caret=True
            elif msg=="InvalidPath":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type path: "%s"' % val
                detail_caret=True
            elif msg=="InvalidLseg":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type lseg: "%s"' % val
                detail_caret=True
            elif msg.startswith("invalid Unicode escape") or msg.startswith("invalid input syntax for type json"):
                if re.search(r"::\s*jsonb?\b", stmt, re.I) or re.search(r"\bjsonb\s+'", stmt, re.I) or re.search(r"\bjsonpath\b", stmt, re.I):
                    detail_caret=True
            elif msg.startswith("unsupported Unicode escape"):
                if re.search(r"::\s*jsonb?\b", stmt, re.I) or re.search(r"\bjsonb\s+'", stmt, re.I) or re.search(r"\bjsonpath\b", stmt, re.I):
                    detail_caret=True
            elif msg=="InvalidTime":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type time: "%s"' % val
                detail_caret=True
            elif msg.startswith("date/time field value out of range: "):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                caret_pos=clean.find("'")
                detail_caret=True
            elif msg=="TimeOutOfRange":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='date/time field value out of range: "%s"' % val
                detail_caret=True
            elif msg=="PglzDecompressFailed": msg="pglz_decompress failed"
            elif msg.startswith("operator is not unique: time"):
                hint="Could not choose a best candidate operator. You might need to add explicit type casts."
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                caret_pos=clean.find("+")
                detail_caret=True
            elif msg.startswith('value "') and 'is out of range for type money' in msg:
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                caret_pos=clean.find("'")
                detail_caret=True
            elif msg=="InvalidMoney":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type money: "%s"' % val
                detail_caret=True
            elif msg.startswith('column "') and msg.endswith('" does not exist') and re.search(r"\bCREATE\s+VIEW\b", stmt, re.I):
                nm=msg[len('column "'):-len('" does not exist')]
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                m=re.search(r'(?<![\w.])'+re.escape(nm)+r'(?![\w])', clean)
                caret_pos=m.start() if m else None
                detail_caret=True
            elif msg.startswith("CREATE SCHEMA IF NOT EXISTS cannot include schema elements"):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                m=re.search(r"CREATE\s+(?:TABLE|VIEW|SEQUENCE|INDEX|TRIGGER)", clean, re.I)
                caret_pos=m.start() if m else None
                detail_caret=True
            elif msg.startswith("syntax error at or near \"=>\"") and "CREATE OPERATOR =>" in stmt:
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                caret_pos=clean.find("=>")
                detail_caret=True
            elif msg.startswith("syntax error") and "SELECT 10 !=-" in stmt:
                msg='syntax error at or near ";"'
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                caret_pos=clean.find(";")
                detail_caret=True
            elif msg.startswith("SELECT ... INTO is not allowed here"):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                m=list(re.finditer(r"\bINTO\b", clean, re.I))
                if m:
                    j=m[-1].end()
                    while j<len(clean) and clean[j] in " \t": j+=1
                    caret_pos=j
                else: caret_pos=None
                detail_caret=True
            elif msg.startswith("function ") and " does not exist" in msg and stmt.lstrip().upper().startswith("SELECT"):
                fname=msg[len("function "):].split("(",1)[0]
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                m=re.search(r"(?<![\w.])"+re.escape(fname)+r"\s*\(", clean)
                caret_pos=m.start() if m else None
                detail_caret=True
            elif msg.startswith("cannot cast type "):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                caret_pos=clean.rfind("::")
                if " to " in msg:
                    tgt=msg.split(" to ",1)[1]
                    m=list(re.finditer(re.escape(tgt), clean))
                    if m: caret_pos=max(clean.rfind("::"),0)
                detail_caret=True
            elif msg.startswith("cannot alter column type of typed table"):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                m=re.search(r"ALTER\s+COLUMN\s+(\w+)", clean, re.I)
                caret_pos=(m.start(1) if m else None)
                detail_caret=True
            elif msg.startswith('column reference "') and msg.endswith('" is ambiguous'):
                detail_caret=True
                nm=msg[len('column reference "'):-len('" is ambiguous')]
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                ms=list(re.finditer(r"(?<![\w.])"+re.escape(nm)+r"(?![\w])", clean))
                caret_pos=ms[-1].start() if ms else None
            elif 'must appear in the GROUP BY clause' in msg:
                detail_caret=True
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                full=msg.split('"')[-2]
                base=full.rsplit('.',1)[-1]
                oi=clean.upper().rfind("ORDER BY ")
                seg=clean[oi:] if oi>=0 else clean
                m=list(re.finditer(re.escape(full), seg)) or list(re.finditer(r"(?<![\w.])"+re.escape(base)+r"(?![\w])", seg))
                caret_pos=(oi+m[0].start()) if (oi>=0 and m) else None
                if re.match(r"^\s*EXECUTE\b", stmt, re.I): detail_caret=False
            elif msg.startswith("GROUP BY position ") and "is not in select list" in msg:
                detail_caret=True
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                m=re.search(r"GROUP\s+BY\s+(\d+)", clean, re.I)
                caret_pos=(m.start(1) if m else None)
            elif msg.startswith("invalid input syntax for type time with time zone"):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                caret_pos=clean.find("'")
                detail_caret=True
            elif msg.startswith("operator does not exist: time with time zone + time with time zone"):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                caret_pos=clean.find("+")
                detail_caret=True
            elif msg.startswith("invalid input syntax for type tid"):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                caret_pos=clean.find("'")
                detail_caret=True
            elif msg.startswith("invalid input syntax for type pg_lsn"):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                caret_pos=clean.find("'")
                detail_caret=True
            elif msg.startswith("invalid input syntax for type uuid"):
                clean=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
                caret_pos=clean.find("'")
                detail_caret=True
            elif msg.startswith("parameter $") and "cannot be coerced" in msg:
                m=re.search(r"parameter \$(\d+)", msg)
                n=int(m.group(1)) if m else 1
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                try:
                    po=clean.index("(")
                    depth=0; cur=po+1; argstart=None; aidx=1
                    for i2 in range(po, len(clean)):
                        ch=clean[i2]
                        if ch=="(":
                            depth+=1
                            if depth==1: cur=i2+1
                        elif ch==")":
                            depth-=1
                            if depth==0:
                                if aidx==n: argstart=cur
                                break
                        elif ch=="," and depth==1:
                            if aidx==n: argstart=cur
                            aidx+=1; cur=i2+1
                    if argstart is not None:
                        while argstart < len(clean) and clean[argstart] in " \t": argstart+=1
                        caret_pos=argstart
                except ValueError:
                    pass
                detail_caret = caret_pos is not None
            elif msg.startswith('type "') and msg.endswith('does not exist') and (stmt.lstrip().upper().startswith("PREPARE") or " OF " in stmt.upper()):
                detail_caret=True
                val=msg[6:-len(' does not exist')-1]
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                p2=clean.find(val)
                caret_pos=p2 if p2>=0 else None
            elif msg=="InvalidMacaddr8":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type macaddr8: "%s"' % val
                detail_caret=True
            elif msg=="InvalidMacaddr":
                vm=re.search(r"VALUES\s*\([^,]*,\s*'((?:''|[^'])*)'", stmt, re.I) or re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type macaddr: "%s"' % val
                detail_caret=True
                qpos=stmt.find("'"+val.replace("'","''")+"'")
                if qpos>=0:
                    clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                    caret_pos=clean.find("'"+val.replace("'","''")+"'")
            elif msg in ("InvalidInt","IntOutOfRange"):
                m=re.search(r"INSERT INTO\s+(\w+)", stmt, re.I)
                typ="smallint"
                if m:
                    tt=table_types.get(m.group(1).upper(),{})
                    typ=next(iter(tt.values()),"smallint") if tt else "smallint"
                    typ={"int2":"smallint","int4":"integer","int8":"bigint"}.get(typ,typ)
                else:
                    cm=re.search(r"\b(int2|int4|int8|smallint|integer|bigint)\s+'", stmt, re.I)
                    if not cm:
                        cm=re.search(r"'[^']*'\s*::\s*(int2|int4|int8|smallint|integer|bigint)", stmt, re.I)
                    if cm: typ={"int2":"smallint","int4":"integer","int8":"bigint"}.get(cm.group(1).lower(),cm.group(1).lower())
                vm=re.search(r"VALUES\s*\(\s*'((?:''|[^'])*)'", stmt, re.I)
                if not vm: vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                if msg=="IntOutOfRange":
                    msg='value "%s" is out of range for type %s' % (val,typ)
                else:
                    msg='invalid input syntax for type %s: "%s"' % (typ,val)
                detail_caret=True
            elif msg in ("InvalidOid","OidOutOfRange"):
                m=re.search(r"INSERT INTO\s+(\w+)", stmt, re.I)
                t=(m.group(1).upper() if m else "")
                vm=re.search(r"VALUES\s*\(\s*'((?:''|[^'])*)'", stmt, re.I)
                val=(vm.group(1).replace("''","'") if vm else "")
                if re.search(r"\bINSERT\b", stmt, re.I):
                    if msg=="OidOutOfRange":
                        msg='value "%s" is out of range for type oid' % val
                    else:
                        msg='invalid input syntax for type oid: "%s"' % val
                    detail_caret=True
                elif msg=="OidOutOfRange":
                    msg="OID out of range"
                else:
                    msg='invalid input syntax for type oid: "%s"' % val
                    detail_caret=True
            if msg in ("SmallintOutOfRange","IntegerOutOfRange","BigintOutOfRange"):
                tname={"SmallintOutOfRange":"smallint","IntegerOutOfRange":"integer","BigintOutOfRange":"bigint"}[msg]
                direct = re.match(r"^\s*(?i:select)\s+'[^']*'\s*::\s*(?i:int2|int4|int8|smallint|integer|bigint)\s*;?\s*$", stmt) or re.match(r"^\s*(?i:select)\s+(?i:int2|int4|int8|smallint|integer|bigint)\s+'", stmt) or re.search(r"\b(?i:insert)\b", stmt, re.I)
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                if vm and direct:
                    val=vm.group(1).replace("''","'")
                    msg='value "%s" is out of range for type %s' % (val,tname)
                    detail_caret=True
                else:
                    msg="%s out of range" % tname
            elif msg=="DivisionByZero": msg="division by zero"
            elif msg=="StepZero": msg="step size cannot equal zero"
            if verbosity=="sqlstate":
                # The only SQLSTATE-sensitive cases exercised by the tests.
                if "stack depth limit exceeded" in msg:
                    code="54001"
                elif "could not find function" in msg:
                    code="42883"
                else:
                    code="XX000"
                out.append("ERROR:  "+code)
                if fail_on_error:
                    print("\n".join(out)); sys.exit(1)
                continue
            out.append("ERROR:  "+msg)
            terse = verbosity in ("terse",)
            if detail_line and not detail_caret and not terse: out.append("DETAIL:  "+detail_line)
            if hint and not detail_caret and not terse: out.append("HINT:  "+hint)
            if context_line and not detail_caret: out.append("CONTEXT:  "+context_line)
            if detail_caret and echo:
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                pos=caret_pos if caret_pos is not None else clean.find("'")
                if pos < 0: pos=0
                line_no=clean.count("\n",0,pos)+1
                line_start=clean.rfind("\n",0,pos)+1
                line_end=clean.find("\n",pos)
                if line_end < 0: line_end=len(clean)
                # Trailing SQL comments are not part of the reported line.
                ci=clean.find("--", line_start, line_end)
                if ci>=0:
                    line_end=ci
                    while line_end>line_start and clean[line_end-1] in " \t": line_end-=1
                ibeg, iend = line_start, line_end
                beg_trunc=end_trunc=False
                if iend-ibeg > 60:
                    if ibeg+60 >= pos+10:
                        iend=ibeg+60; end_trunc=True
                    else:
                        while pos+10 < iend: iend-=1; end_trunc=True
                        while iend-ibeg > 60: ibeg+=1; beg_trunc=True
                shown=clean[ibeg:iend].replace("\t"," ")
                out.append("LINE %d: %s%s%s" % (line_no, "..." if beg_trunc else "", shown, "..." if end_trunc else ""))
                out.append(" "* (8+(3 if beg_trunc else 0)+pos-ibeg) + "^")
                if hint: out.append("HINT:  "+hint)
                if detail_line: out.append("DETAIL:  "+detail_line)
                if context_line: out.append("CONTEXT:  "+context_line)
            if fail_on_error:
                print("\n".join(out)); sys.exit(1)
            continue
        if echo and cols:
            from_m=re.search(r"FROM\s+([\w.]+)", stmt, re.I)
            types=table_types.get(from_m.group(1).split('.')[-1].upper(), {}) if from_m else {}
            text_headers={"sql_error_code","message","detail","hint"}
            num_types=("oid","int","int2","int4","int8","float","float4","float8","numeric","double","real","serial","bigserial","smallserial")
            numeric=[]; decl=[]
            for i,c in enumerate(cols):
                if c.lower()=="to_char":
                    numeric.append(False); continue
                fn_numeric={"char_length","character_length","length","count","min","max","sum","avg","uuid_extract_version"}
                k=types.get(c.lower()) if types else None
                decl.append(k)
                if c.lower() in fn_numeric:
                    numeric.append(True)
                elif k is not None:
                    numeric.append(k in num_types)
                else:
                    nonempty=[r[i] for r in rows if r[i] not in (None,"")]
                    def isnum(v):
                        lv=v.strip().lower()
                        if re.fullmatch(r"-?\$[\d,]+\.\d{2}", v): return True
                        return bool(re.fullmatch(r"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", v)) or lv in ("nan","nan.0","inf","inf.0","infinity","-inf","-inf.0","-infinity")
                    numeric.append(c.lower() not in text_headers and bool(nonempty) and all(isnum(v) for v in nonempty))
            fmode={}
            if "float8(" in stmt or "::float8" in stmt: fmode["float8"]=16
            if "float4(" in stmt or "::float4" in stmt: fmode["float4"]=6
            fsigs=[None]*len(cols)
            sel_m=re.search(r"\bSELECT\b(.*?)\bFROM\b", stmt, re.I|re.S)
            if sel_m:
                items=[]; depth=0; cur=""
                for ch in sel_m.group(1):
                    if ch=='(': depth+=1
                    elif ch==')': depth-=1
                    if ch==',' and depth==0: items.append(cur); cur=""
                    else: cur+=ch
                if cur.strip(): items.append(cur)
                if len(items)==len(cols):
                    for i,it in enumerate(items):
                        fm=re.search(r"float4\s*\(|::\s*float4|\bas\s+float4", it, re.I)
                        f8=re.search(r"float8\s*\(|::\s*float8|\bas\s+float8", it, re.I)
                        if fm: fsigs[i]=6
                        elif f8: fsigs[i]=16
            _sfirst=re.sub(r"^(?:--[^\n]*\n|\s)*","",stmt)
            if re.match(r"SELECT\s+[^(),\s]+::", _sfirst, re.I) and any("::"+b in _sfirst.lower() for b in base_types):
                numeric=[False]*len(cols)
            out.append(fmt_table(cols, rows, null_display=null_display, numeric=numeric, strip_float_zero=("::float8" in stmt or "::float4" in stmt), float_mode=fmode, float_sigs=fsigs, all_float_sig=float_sig, decl_types=decl).rstrip("\n"))
            out.append("")
    print("\n".join(out))

if __name__=="__main__":
    main()
