{
open Parser

exception LexError of string

(* Indentation tracking *)
let indent_stack = Stack.create ()
let () = Stack.push 0 indent_stack

let pending_tokens : token Queue.t = Queue.create ()
let paren_depth = ref 0
let fstr_brace_depth = ref 0   (* {} nesting depth inside an f-string expression *)
let fstr_body_buf = Buffer.create 64  (* accumulates f-string literal chars *)
let in_fstring_body = ref false  (* when true, token dispatcher calls fstring_body *)

let reset_lexer () =
  Stack.clear indent_stack;
  Stack.push 0 indent_stack;
  Queue.clear pending_tokens;
  paren_depth := 0;
  fstr_brace_depth := 0;
  Buffer.clear fstr_body_buf;
  in_fstring_body := false

let current_indent () = Stack.top indent_stack

let emit_indentation indent =
  let cur = current_indent () in
  if indent > cur then begin
    Stack.push indent indent_stack;
    Queue.push NEWLINE pending_tokens;
    Queue.push INDENT pending_tokens
  end else if indent < cur then begin
    Queue.push NEWLINE pending_tokens;
    let dedent () =
      let top = current_indent () in
      if indent > top then
        raise (LexError (Printf.sprintf "Inconsistent dedent: got %d, expected %d" indent top))
    in
    while indent < current_indent () do
      ignore (Stack.pop indent_stack);
      Queue.push DEDENT pending_tokens
    done;
    dedent ()
  end else begin
    Queue.push NEWLINE pending_tokens
  end

let close_indents () =
  Queue.push NEWLINE pending_tokens;
  while Stack.length indent_stack > 1 do
    ignore (Stack.pop indent_stack);
    Queue.push DEDENT pending_tokens
  done;
  Queue.push EOF pending_tokens
}

let digit = ['0'-'9']
let alpha = ['a'-'z' 'A'-'Z' '_']
let alnum = ['a'-'z' 'A'-'Z' '0'-'9' '_']

rule line_start = parse
  | [' ']* '#' [^ '\n']* '\n'
    { Lexing.new_line lexbuf; line_start lexbuf }  (* skip comment lines *)
  | [' ']* '\n'
    { Lexing.new_line lexbuf; line_start lexbuf }  (* skip blank lines *)
  | ([' ']* as spaces)
    { let indent = String.length spaces in
      emit_indentation indent;
      if Queue.is_empty pending_tokens then
        main lexbuf
      else
        Queue.pop pending_tokens
    }
  | eof
    { close_indents ();
      Queue.pop pending_tokens
    }

and main = parse
  | [' ' '\t']+ { main lexbuf }

  | '\n'
    { Lexing.new_line lexbuf;
      if !paren_depth > 0 then
        main lexbuf
      else
        line_start lexbuf
    }

  | '#' [^ '\n']* { main lexbuf }

  (* Keywords *)
  | "def"       { DEF }
  | "return"    { RETURN }
  | "if"        { IF }
  | "elif"      { ELIF }
  | "else"      { ELSE }
  | "for"       { FOR }
  | "in"        { IN }
  | "while"     { WHILE }
  | "struct"    { STRUCT }
  | "import"    { IMPORT }
  | "and"       { AND }
  | "or"        { OR }
  | "not"       { NOT }
  | "True"      { TRUE }
  | "False"     { FALSE }
  | "pass"      { PASS }
  | "break"     { BREAK }
  | "print"     { PRINT }
  | "range"     { RANGE }
  | "sync"      { SYNC }
  | "allocate"  { ALLOCATE }
  | "int"       { TINT }
  | "float"     { TFLOAT }
  | "bool"      { TBOOL }
  | "string"    { TSTRING }
  | "array"     { ARRAY }
  | "callable"  { CALLABLE }
  | "void"      { TVOID }

  (* Decorator *)
  | "@local_init" { AT_LOCAL_INIT }
  | "@local"      { AT_LOCAL }
  | "@reduce"     { AT_REDUCE }
  | "@gpu"        { AT_GPU }
  | "@omp"        { AT_OMP }
  | "@par"        { AT_PAR }

  (* Multi-char operators *)
  | "->"        { ARROW }
  | "**"        { DOUBLESTAR }
  | ".."        { DOTDOT }
  | "+="        { PLUSEQ }
  | "-="        { MINUSEQ }
  | "*="        { STAREQ }
  | "/="        { SLASHEQ }
  | "=="        { EQEQ }
  | "!="        { NEQ }
  | "<="        { LE }
  | ">="        { GE }

  (* Single-char operators *)
  | '<'         { LT }
  | '>'         { GT }
  | '+'         { PLUS }
  | '-'         { MINUS }
  | '*'         { STAR }
  | '/'         { SLASH }
  | '%'         { PERCENT }
  | '='         { EQ }

  (* Delimiters *)
  | '('         { incr paren_depth; LPAREN }
  | ')'         { decr paren_depth; RPAREN }
  | '['         { incr paren_depth; LBRACKET }
  | ']'         { decr paren_depth; RBRACKET }
  | '{'
    { if !fstr_brace_depth > 0 then incr fstr_brace_depth;
      incr paren_depth; LBRACE }
  | '}'
    { if !fstr_brace_depth > 0 then begin
        decr fstr_brace_depth;
        if !fstr_brace_depth = 0 then begin
          (* This } closes the f-string expression; return to literal scanning. *)
          decr paren_depth;
          Buffer.clear fstr_body_buf;
          in_fstring_body := true;
          FSTRING_EXPR_END
        end else begin
          decr paren_depth; RBRACE
        end
      end else begin
        decr paren_depth; RBRACE
      end }
  | ':'         { COLON }
  | ','         { COMMA }
  | '.'         { DOT }

  (* Float literals - must come before int *)
  | digit+ '.' digit* (['e' 'E'] ['+' '-']? digit+)? as f
    { FLOAT_LIT (float_of_string f) }
  | digit+ ['e' 'E'] ['+' '-']? digit+ as f
    { FLOAT_LIT (float_of_string f) }

  (* Integer literals *)
  | digit+ as n
    { INT_LIT (int_of_string n) }

  (* F-string: f"..." with {expr} interpolation *)
  | "f\""
    { Buffer.clear fstr_body_buf;
      in_fstring_body := true;
      FSTRING_OPEN }

  (* String literals *)
  | '"' ([^ '"' '\n']* as s) '"'   { STRING_LIT s }
  | '\'' ([^ '\'' '\n']* as s) '\'' { STRING_LIT s }

  (* Identifiers *)
  | alpha alnum* as id { IDENT id }

  | eof
    { close_indents ();
      Queue.pop pending_tokens
    }

  | _ as c { raise (LexError (Printf.sprintf "Unexpected character: '%c' at line %d" c lexbuf.lex_curr_p.pos_lnum)) }

and fstring_body = parse
  | '{'
    { (* Start of interpolated expression; switch back to main for expr tokens. *)
      let frag = Buffer.contents fstr_body_buf in
      Buffer.clear fstr_body_buf;
      fstr_brace_depth := 1;
      incr paren_depth;
      in_fstring_body := false;
      if frag <> "" then begin
        Queue.push FSTRING_EXPR_START pending_tokens;
        STR_FRAG frag
      end else
        FSTRING_EXPR_START }
  | '"'
    { (* End of f-string literal; return to normal lexing. *)
      let frag = Buffer.contents fstr_body_buf in
      Buffer.clear fstr_body_buf;
      in_fstring_body := false;
      if frag <> "" then begin
        Queue.push FSTRING_CLOSE pending_tokens;
        STR_FRAG frag
      end else
        FSTRING_CLOSE }
  | [^ '{' '"'] as c
    { Buffer.add_char fstr_body_buf c;
      fstring_body lexbuf }
  | eof
    { raise (LexError "Unterminated f-string") }

{
(* Entry point: drain pending queue, then dispatch to fstring_body or main. *)
let token lexbuf =
  if not (Queue.is_empty pending_tokens) then
    Queue.pop pending_tokens
  else if !in_fstring_body then
    fstring_body lexbuf
  else
    main lexbuf

(* Initial entry must handle first-line indentation *)
let init_and_token lexbuf =
  reset_lexer ();
  line_start lexbuf
}
