REBAR=rebar
REBAR_COMPILE=$(REBAR) get-deps compile
PLT=dialyzer\sqlite3.plt
ERL_INTERFACE=$(ERL_ROOT)\lib\erl_interface-3.7.18
ERTS=$(ERL_ROOT)\erts-6.2
SQLITE_SRC=F:\MyProgramming\sqlite-amalgamation

all: compile

compile: 
	$(REBAR_COMPILE)

debug:
	$(REBAR_COMPILE) -C rebar.debug.config

tests:
	if not exist .eunit mkdir .eunit
	cp sqlite3.dll .eunit
	$(REBAR_COMPILE) skip_deps=true eunit

clean:
	if exist deps del /Q deps
	if exist ebin del /Q ebin
	if exist priv del /Q priv
	if exist doc\* del /Q doc\*
	if exist .eunit del /Q .eunit
	if exist c_src\*.o del /Q c_src\*.o

docs:
	$(REBAR_COMPILE) doc

static: compile
	@if not exist $(PLT) \
		(mkdir dialyzer & dialyzer --build_plt --apps kernel stdlib erts --output_plt $(PLT)); \
	else \
		(dialyzer --plt $(PLT) -r ebin)

cross_compile: clean
	$(REBAR_COMPILE) -C rebar.cross_compile.config
