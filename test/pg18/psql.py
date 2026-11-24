#!/usr/bin/env python3
"""Tiny psql-like client for the zhdb wire protocol (test harness only)."""
import socket, struct, sys, re, os

def msg(tag, payload=b""):
    return tag + struct.pack("!I", len(payload) + 4) + payload

class Client:
    def __init__(self, port, user="zhdb", db="postgres"):
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

    def query(self, sql):
        self.s.sendall(msg(b"Q", sql.encode() + b"\x00"))
        cols = None; rows = []; err = None
        while True:
            tag, body = self._recv()
            if tag == b"T":
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
            elif tag == b"E":
                err = self._err(body)
            elif tag == b"Z":
                break
        if err:
            raise RuntimeError(err)
        return cols or [], rows

def split_sql(src):
    out=[]; start=0; i=0; n=len(src); quote=None
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
        if c==';':
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

def fmt_table(cols, rows, null_display="", numeric=None, strip_float_zero=False, float_mode=None, float_sigs=None, all_float_sig=None):
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
    widths=[]
    for ci,c in enumerate(cols):
        widths.append(max([len(c)] + [len(r[ci]) for r in vals]) + 2)
    cols=["char" if c=='"char"' else c for c in cols]
    def centered(c,w):
        pad=max(0,w-len(c)); return " "*(pad//2)+c+" "*(pad-pad//2)
    hdr="|".join(" "+centered(c,widths[i]-2)+" " for i,c in enumerate(cols))
    sep="+".join("-"*w for w in widths)
    body=[]
    for r in vals:
        parts=[]
        for i in range(len(cols)):
            if numeric[i]: parts.append(" "+r[i].rjust(widths[i]-2)+" ")
            else: parts.append(" "+r[i]+" "*(widths[i]-2-len(r[i]))+" ")
        line="|".join(parts)
        if line.strip()=="" and len(cols)==1: line=" "*(1+len(r[0]))
        elif numeric[-1] and r and r[-1]=="": line=line[:-1]
        elif r and r[-1].endswith(" "): line=line[:-1]
        else: line=line.rstrip()
        body.append(line)
    body.append("(%d row%s)" % (len(rows), "" if len(rows)==1 else "s"))
    return "\n".join([hdr,sep]+body)+"\n"

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
    for raw, _ in split_sql(src):
        # Echo-only meta lines inserted by prep.py (psql -a output).
        if "\\_echo " in raw:
            kept=[]
            for ln in raw.splitlines(True):
                if ln.strip().startswith("\\_echo "):
                    txt=ln.strip()[7:]
                    if txt.strip(): out.append(txt)
                else:
                    kept.append(ln)
            raw="".join(kept)
        # strip leading blank lines and comments-only prefix for execution
        stmt=raw.strip()
        if not stmt: continue
        sm=re.search(r"\bSET\s+extra_float_digits\s*=\s*(-?\d+)", stmt, re.I)
        if sm:
            n=15+int(sm.group(1))
            float_sig=n if n>0 else None
        if echo:
            shown="\n".join(l for l in raw.splitlines() if l.strip())
            if shown.startswith('\\') and shown.rstrip().endswith(';'):
                shown=shown.rstrip()[:-1]
            if shown: out.append(shown)
        if stmt.startswith('\\_echo '):
            text=stmt[7:].rstrip()
            if text.endswith(';'): text=text[:-1]
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
        drop_m=re.search(r"DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?(\w+)", stmt, re.I)
        if drop_m:
            t=drop_m.group(1).upper()
            if t in temp_prev:
                if temp_prev[t] is None: schema.pop(t,None)
                else: schema[t]=temp_prev[t]
                temp_prev.pop(t,None)
        try:
            cols, rows=cli.query(stmt)
        except RuntimeError as e:
            msg=str(e)
            detail_caret=False
            caret_pos=None
            hint=None
            detail_line=None
            if "\nDETAIL:  " in msg:
                msg, detail_line = msg.split("\nDETAIL:  ", 1)
            if "\nHINT:  " in msg:
                msg, hint = msg.split("\nHINT:  ", 1)
            if msg=="ValueTooLong":
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
                mm=re.search(r"\b"+re.escape(base)+r"\b", clean)
                caret_pos=mm.start() if mm else None
                detail_caret=True
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
            elif msg=="InvalidTime":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type time: "%s"' % val
                detail_caret=True
            elif msg=="TimeOutOfRange":
                vm=re.search(r"'((?:''|[^'])*)'", stmt)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='date/time field value out of range: "%s"' % val
                detail_caret=True
            elif msg.startswith("operator is not unique: time"):
                hint="Could not choose a best candidate operator. You might need to add explicit type casts."
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                caret_pos=clean.find("+")
                detail_caret=True
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
            out.append("ERROR:  "+msg)
            if detail_line: out.append("DETAIL:  "+detail_line)
            if detail_caret and echo:
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                pos=caret_pos if caret_pos is not None else clean.find("'")
                if pos < 0: pos=0
                line_no=clean.count("\n",0,pos)+1
                line_start=clean.rfind("\n",0,pos)+1
                line_end=clean.find("\n",pos)
                if line_end < 0: line_end=len(clean)
                shown=clean[line_start:line_end]
                if shown.find("--")>=0: shown=shown[:shown.find("--")].rstrip()
                if len(shown)>63: shown=shown[:60]+"..."
                out.append("LINE %d: %s" % (line_no, shown))
                out.append(" "* (8+pos-line_start) + "^")
                if hint: out.append("HINT:  "+hint)
            if fail_on_error:
                print("\n".join(out)); sys.exit(1)
            continue
        if echo and cols:
            from_m=re.search(r"FROM\s+(\w+)", stmt, re.I)
            types=table_types.get(from_m.group(1).upper(), {}) if from_m else {}
            text_headers={"sql_error_code","message","detail","hint"}
            num_types=("oid","int","int2","int4","int8","float","float4","float8","numeric","double","real","serial","bigserial","smallserial")
            numeric=[]
            for i,c in enumerate(cols):
                if c.lower()=="to_char":
                    numeric.append(False); continue
                fn_numeric={"char_length","character_length","length","count","min","max","sum","avg"}
                k=types.get(c.lower()) if types else None
                if c.lower() in fn_numeric:
                    numeric.append(True)
                elif k is not None:
                    numeric.append(k in num_types)
                else:
                    nonempty=[r[i] for r in rows if r[i] not in (None,"")]
                    def isnum(v):
                        lv=v.strip().lower()
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
            out.append(fmt_table(cols, rows, null_display=null_display, numeric=numeric, strip_float_zero=("::float8" in stmt or "::float4" in stmt), float_mode=fmode, float_sigs=fsigs, all_float_sig=float_sig).rstrip("\n"))
            out.append("")
    print("\n".join(out))

if __name__=="__main__":
    main()
