; sqlite3.inc - private ABI shared by src/modules/sqlite3.asm and
; src/modules/sqlite3_cb.asm.
;
; src/modules/sqlite3.asm is called BY Python (_sqlite3core);
; src/modules/sqlite3_cb.asm is called BY libsqlite3.  They are separate
; files because the two sides have opposite error discipline and GIL state:
; blocking libsqlite3 calls release the GIL, so callbacks re-acquire it on
; entry (when not already held by this thread) and never RAISE into the
; unwinder.

%ifndef SQLITE3_INC
%define SQLITE3_INC

; Handle magics -- freed slots are zeroed so stale handles never look live.
SQ_DB_MAGIC     equ 0x53514442      ; "SQDB"
SQ_STMT_MAGIC   equ 0x53515354      ; "SQST"
SQ_BLOB_MAGIC   equ 0x5351424C      ; "SQBL"
SQ_BKUP_MAGIC   equ 0x5351424B      ; "SQBK"
SQ_CB_MAGIC     equ 0x53514342      ; "SQCB"

; SQLite result codes used by the core shim (from /usr/include/sqlite3.h).
SQLITE_OK           equ 0
SQLITE_ERROR        equ 1
SQLITE_NOMEM        equ 7
SQLITE_TOOBIG       equ 18
SQLITE_ROW          equ 100
SQLITE_DONE         equ 101

; SQLite fundamental datatypes.
SQLITE_INTEGER      equ 1
SQLITE_FLOAT        equ 2
SQLITE_TEXT         equ 3
SQLITE_BLOB         equ 4
SQLITE_NULL         equ 5

; SQLite open flags.
SQLITE_OPEN_READONLY    equ 0x00000001
SQLITE_OPEN_READWRITE   equ 0x00000002
SQLITE_OPEN_CREATE      equ 0x00000004
SQLITE_OPEN_URI         equ 0x00000040
SQLITE_OPEN_NOMUTEX     equ 0x00008000
SQLITE_OPEN_FULLMUTEX   equ 0x00010000

; Function registration flags.
SQLITE_UTF8             equ 1
SQLITE_DETERMINISTIC    equ 0x00000800

; Destructor sentinel: tells SQLite to copy text/blob immediately.
SQLITE_TRANSIENT        equ -1

; Trace mask for sqlite3_trace_v2.
SQLITE_TRACE_STMT       equ 0x01

; Deserialize flags.
SQLITE_DESERIALIZE_FREEONCLOSE  equ 1
SQLITE_DESERIALIZE_RESIZEABLE   equ 2

; Authorizer return codes.
SQLITE_DENY             equ 1
SQLITE_IGNORE           equ 2

; Callback kinds (SqlCb.kind).
SQ_CB_FUNC          equ 0
SQ_CB_AGGREGATE     equ 1
SQ_CB_WINDOW        equ 2
SQ_CB_COLLATION     equ 3
SQ_CB_AUTHORIZER    equ 4
SQ_CB_PROGRESS      equ 5
SQ_CB_TRACE         equ 6

; One open sqlite3* connection.
struc SqlDb
    .magic:         resq 1          ; SQ_DB_MAGIC while open, 0 once freed
    .db:            resq 1          ; sqlite3*
    .trace_cb:      resq 1          ; SqlCb* or 0
    .progress_cb:   resq 1          ; SqlCb* or 0
    .auth_cb:       resq 1          ; SqlCb* or 0
endstruc

; One prepared sqlite3_stmt*.
struc SqlStmt
    .magic:         resq 1          ; SQ_STMT_MAGIC while live
    .stmt:          resq 1          ; sqlite3_stmt*
    .db_h:          resq 1          ; owning SqlDb handle index
endstruc

; One open sqlite3_blob*.
struc SqlBlob
    .magic:         resq 1          ; SQ_BLOB_MAGIC while open
    .blob:          resq 1          ; sqlite3_blob*
    .db_h:          resq 1          ; owning SqlDb handle index
endstruc

; One live sqlite3_backup*.
struc SqlBackup
    .magic:         resq 1          ; SQ_BKUP_MAGIC while open
    .bkup:          resq 1          ; sqlite3_backup*
endstruc

; Callback context passed as user data / pApp to libsqlite3.
struc SqlCb
    .magic:         resq 1          ; SQ_CB_MAGIC while live
    .callable:      resq 1          ; owned Python Value (callable or class)
    .kind:          resq 1          ; SQ_CB_*
    .db_h:          resq 1          ; owning SqlDb handle index
endstruc

; Aggregate/window per-group state stored inside sqlite3_aggregate_context.
struc SqlAggCtx
    .instance:      resq 1          ; owned Python Value, or 0
    .failed:        resq 1          ; 1 once init or step raised
endstruc

%endif ; SQLITE3_INC
