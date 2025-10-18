# META
~~~ini
description=Singleline with comma formatting app
type=file
~~~
# SOURCE
~~~roc
app [a1!, a2!,] { pf: platform "../basic-cli/main.roc", a: "a", }
~~~
# EXPECTED
EXPOSED BUT NOT DEFINED - app.md:1:11:1:14
EXPOSED BUT NOT DEFINED - app.md:1:6:1:9
# PROBLEMS
**EXPOSED BUT NOT DEFINED**
The module header says that `a2!` is exposed, but it is not defined anywhere in this module.

**app.md:1:11:1:14:**
```roc
app [a1!, a2!,] { pf: platform "../basic-cli/main.roc", a: "a", }
```
          ^^^
You can fix this by either defining `a2!` in this module, or by removing it from the list of exposed values.

**EXPOSED BUT NOT DEFINED**
The module header says that `a1!` is exposed, but it is not defined anywhere in this module.

**app.md:1:6:1:9:**
```roc
app [a1!, a2!,] { pf: platform "../basic-cli/main.roc", a: "a", }
```
     ^^^
You can fix this by either defining `a1!` in this module, or by removing it from the list of exposed values.

# TOKENS
~~~zig
KwApp,OpenSquare,LowerIdent,Comma,LowerIdent,Comma,CloseSquare,OpenCurly,LowerIdent,OpColon,KwPlatform,StringStart,StringPart,StringEnd,Comma,LowerIdent,OpColon,StringStart,StringPart,StringEnd,Comma,CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(app
		(provides
			(exposed-lower-ident
				(text "a1!"))
			(exposed-lower-ident
				(text "a2!")))
		(record-field (name "pf")
			(e-string
				(e-string-part (raw "../basic-cli/main.roc"))))
		(packages
			(record-field (name "pf")
				(e-string
					(e-string-part (raw "../basic-cli/main.roc"))))
			(record-field (name "a")
				(e-string
					(e-string-part (raw "a"))))))
	(statements))
~~~
# FORMATTED
~~~roc
app [
	a1!,
	a2!,
] {
	pf: platform "../basic-cli/main.roc",
	a: "a",
}
~~~
# CANONICALIZE
~~~clojure
(can-ir (empty true))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(expressions))
~~~
