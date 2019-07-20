REBAR=rebar
PLT=dialyzer\sqlite3.plt
REBAR_COMPILE=$(REBAR) get-deps compile

all: compile

compile: sqlite3.dll sqlite3.lib
	$(REBAR_COMPILE)

debug: sqlite3.dll sqlite3.lib
	$(REBAR_COMPILE) -C rebar.debug.config

tests: compile sqlite3.dll
	cp sqlite3.dll priv
	rebar skip-deps=true eunit

clean:
	if exist deps del /Q deps
	if exist ebin del /Q ebin
	if exist doc\* del /Q doc\*
	if exist priv\*.exp del /Q priv\*.exp
	if exist priv\*.lib del /Q priv\*.lib
	if exist .eunit del /Q .eunit
	if exist c_src\*.o del /Q c_src\*.o
	if exist dialyzer del /Q dialyzer
	if exist sqlite3.* del /Q sqlite3.*
	if exist *.pdb del /Q *.pdb

docs: compile
	rebar doc

static: compile
	@if not exist $(PLT) \
		(mkdir dialyzer & dialyzer --build_plt --apps kernel stdlib erts --output_plt $(PLT)); \
	else \
		(dialyzer --plt $(PLT) -r ebin)

cross_compile: clean
	$(REBAR_COMPILE) -C rebar.cross_compile.config

sqlite3.dll: sqlite3_amalgamation\sqlite3.c sqlite3_amalgamation\sqlite3.h
	cl /O2 sqlite3_amalgamation\sqlite3.c /Isqlite3_amalgamation /link /dll /out:sqlite3.dll

sqlite3.lib: sqlite3.dll
	lib /out:sqlite3.lib sqlite3.obj
