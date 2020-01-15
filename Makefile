REBAR=rebar
PLT=dialyzer/sqlite3.plt
REBAR_COMPILE=$(REBAR) get-deps compile

all: compile

compile:
	$(REBAR_COMPILE)

debug:
	$(REBAR_COMPILE) -C rebar.debug.config

tests: compile
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
	if exist *.pdb del /Q *.pdb
	if exist *.i del /Q *.i

docs: compile
	rebar doc

static: compile
	@if not exist $(PLT) \
		(mkdir dialyzer & dialyzer --build_plt --apps kernel stdlib erts --output_plt $(PLT)); \
	else \
		(dialyzer --plt $(PLT) -r ebin)

cross_compile: clean
	$(REBAR_COMPILE) -C rebar.cross_compile.config

#priv/sqlite3.lib: sqlite3_amalgamation/sqlite3.c sqlite3_amalgamation/sqlite3.h
#	cl /O2 sqlite3_amalgamation/sqlite3.c /Isqlite3_amalgamation /link /out:priv/sqlite3.lib

#priv/sqlite3.lib: sqlite3.dll
#	lib /out:priv/sqlite3.lib priv/sqlite3.obj
