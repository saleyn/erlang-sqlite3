%%%-------------------------------------------------------------------
%%% File    : sqlite3.erl
%%% @author Tee Teoh
%%% @copyright 21 Jun 2008 by Tee Teoh
%%% @version 1.0.0
%%% @doc Library module for sqlite3
%%%
%%% @type table_id() = atom() | binary() | string()
%%% @end
%%%-------------------------------------------------------------------
-module(sqlite3).
-include("sqlite3.hrl").
-export_types([sql_value/0, sql_type/0, table_info/0, sqlite_error/0,
               sql_params/0, sql_non_query_result/0, sql_result/0]).

-behaviour(gen_server).

%% API
-export([open/1, open/2]).
-export([start_link/1, start_link/2]).
-export([stop/0, close/1, close_timeout/2]).
-export([enable_load_extension/2]).
-export([sql_exec/1, sql_exec/2, sql_exec_timeout/3,
         sql_exec_script/2, sql_exec_script_timeout/3,
         sql_exec/3, sql_exec_timeout/4]).
-export([prepare/2, bind/3, next/2, reset/2, clear_bindings/2, finalize/2,
         columns/2, prepare_timeout/3, bind_timeout/4, next_timeout/3,
         reset_timeout/3, clear_bindings_timeout/3, finalize_timeout/3,
         columns_timeout/3]).
-export([create_table/2, create_table/3, create_table/4, create_table_timeout/4,
         create_table_timeout/5]).
-export([add_columns/2, add_columns/3]).
-export([list_tables/0, list_tables/1, list_tables_timeout/2,
         table_exists/1, table_exists/2, table_exists/3,
         table_info/1, table_info/2, table_info_timeout/3, describe_table/2]).
-export([write/2, write/3, write_timeout/4, write_many/2, write_many/3,
         write_many_timeout/4]).
-export([update/3, update/4, update_timeout/5]).
-export([read_all/2, read_all/3, read_all_timeout/3, read_all_timeout/4,
         read/2, read/3, read/4, read_timeout/4, read_timeout/5]).
-export([delete/2, delete/3, delete_timeout/4]).
-export([drop_table/1, drop_table/2, drop_table_timeout/3]).
-export([vacuum/0, vacuum/1, vacuum_timeout/2]).
-export([changes/1, changes/2]).
-export([filename/1]).

%% -export([create_function/3]).

-export([value_to_sql/1, value_to_sql_unsafe/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define('DRIVER_NAME', 'sqlite3_drv').
-record(state, {port, ops = [], refs = dict:new()}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @doc
%%   Opens the sqlite3 database in file DbName.db in the working directory
%%   (creating this file if necessary). This is the same as open/1.
%% @end
%%--------------------------------------------------------------------
-type option() :: {file, string()} | temporary | in_memory | debug |
                  open_db_option().

%% See flags or sqlite3_open_v2()
%% https://www.sqlite.org/c3ref/open.html
-type open_db_option() ::
                  readonly        |
                  readwrite       |
                  create          |
                  delete_on_close |
                  exclusive       |
                  auto_proxy      |
                  uri             |
                  memory          |
                  main_db         |
                  temp_db         |
                  transient       |
                  main_journal    |
                  temp_journal    |
                  master_journal  |
                  no_mutex        |
                  full_mutex      |
                  shared_cache    |
                  private_cache   |
                  wal.

-type result() :: {'ok', pid()} | 'ignore' | {'error', any()}.
-type db() :: atom() | pid().

-spec start_link(atom()) -> result().
start_link(DbName) ->
    open(DbName, []).

%%--------------------------------------------------------------------
%% @doc
%%   Opens a sqlite3 database creating one if necessary. By default the
%%   database will be called DbName.db in the current path. This can be changed
%%   by passing the option {file, DbFile :: String()}. DbFile must be the
%%   full path to the sqlite3 db file. start_link/1 can be use with stop/0,
%%   sql_exec/1, create_table/2, list_tables/0, table_info/1, write/2,
%%   read/2, delete/2 and drop_table/1. This is the same as open/2.
%% @end
%%--------------------------------------------------------------------
-spec start_link(atom(), [option()]) -> result().
start_link(DbName, Options) ->
    open(DbName, Options).

%%--------------------------------------------------------------------
%% @doc
%%   Opens the sqlite3 database in file DbName.db in the working directory
%%   (creating this file if necessary).
%% @end
%%--------------------------------------------------------------------
-spec open(atom()) -> result().
open(DbName) ->
    open(DbName, []).

%%--------------------------------------------------------------------
%% @spec open(DbName :: atom(), Options :: [option()]) -> {ok, Pid :: pid()} | ignore | {error, Error}
%% @type option() = {file, DbFile :: string()}
%%                | in_memory | temporary | shared_cache
%%
%% @doc
%%   Opens a sqlite3 database creating one if necessary. By default the database
%%   will be called `DbName.db' in the current path (unless Db is `anonymous', see below).
%%   This can be changed by passing the option `{file, DbFile::string()}'. DbFile
%%   must be the full path to the sqlite3 db file. Can be used to open multiple sqlite3
%%   databases per node. Must be use in conjunction with `stop/1', `sql_exec/2',
%%   `create_table/3', `list_tables/1', `table_info/2', `write/3', `read/3', `delete/3'
%%   and `drop_table/2'. If the name is an atom other than `anonymous', it's used for
%%   registering the gen_server and must be unique. If the name is `anonymous',
%%   the process isn't registered.
%%
%%   Options:
%%   <dl>
%%     <dt>{file, DbFile::string()}</dt><dd>Database filename</dd>
%%     <dt>in_memory</dt><dd>Create in-memory database</dd>
%%     <dt>temporary</dt><dd>Create temp database without a filename</dd>
%%     <dt>shared_cache</dt><dd>Enabled shared cache (see
%%          https://www.sqlite.org/c3ref/enable_shared_cache.html)</dd>
%%   </dl>
%% @end
%%--------------------------------------------------------------------
-spec open(atom(), [option()]) -> result().
open(DbName, Options) ->
    IsAnonymous    = DbName =:= anonymous,
    {Opts1, Opts2} = lists:partition(fun(I) -> lists:member(I,[in_memory, temporary]) end, Options),
    Opts = case proplists:lookup(file, Opts2) of
               none ->
                   DbFile = case proplists:is_defined(in_memory, Opts1) of
                                true ->
                                    ":memory:";
                                false ->
                                    case IsAnonymous orelse proplists:is_defined(temporary, Opts1) of
                                        true ->
                                            "";
                                        false ->
                                            "./" ++ atom_to_list(DbName) ++ ".db"
                                    end
                            end,
                   [{file, DbFile} | Opts2];
               {file, _} ->
                   Opts2
           end,
    if
        IsAnonymous -> gen_server:start_link(?MODULE, Opts, []);
        true -> gen_server:start_link({local, DbName}, ?MODULE, Opts, [])
    end.

%%--------------------------------------------------------------------
%% @doc
%%   Closes the Db sqlite3 database.
%% @end
%%--------------------------------------------------------------------
-spec close(db()) -> 'ok'.
close(Db) ->
    catch gen_server:call(Db, close),
    ok.

%%--------------------------------------------------------------------
%% @doc
%%   Closes the Db sqlite3 database.
%% @end
%%--------------------------------------------------------------------
-spec close_timeout(db(), timeout()) -> 'ok'.
close_timeout(Db, Timeout) ->
    catch gen_server:call(Db, close, Timeout),
    ok.

%%--------------------------------------------------------------------
%% @doc
%%   Closes the sqlite3 database.
%% @end
%%--------------------------------------------------------------------
-spec stop() -> 'ok'.
stop() ->
    close(?MODULE).

enable_load_extension(Db, Value) ->
    gen_server:call(Db, {enable_load_extension, Value}).

%%--------------------------------------------------------------------
%% @doc
%%   Get affected rows.
%% @end
%%--------------------------------------------------------------------

changes(Db) ->
    gen_server:call(Db, changes).

changes(Db, Timeout) ->
    gen_server:call(Db, changes, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Get database filename.
%% @end
%%--------------------------------------------------------------------

filename(Db) ->
    gen_server:call(Db, filename).

%%--------------------------------------------------------------------
%% @doc
%%   Executes the Sql statement directly.
%% @end
%%--------------------------------------------------------------------
-spec sql_exec(iodata()) -> sql_result().
sql_exec(SQL) ->
    sql_exec(?MODULE, SQL).

%%--------------------------------------------------------------------
%% @doc
%%   Executes the Sql statement directly on the Db database. Returns the
%%   result of the Sql call.
%% @end
%%--------------------------------------------------------------------
-spec sql_exec(db(), iodata()) -> sql_result().
sql_exec(Db, SQL) ->
    gen_server:call(Db, {sql_exec, SQL}).

%%--------------------------------------------------------------------
%% @doc
%%   Executes the Sql statement with parameters Params directly on the Db
%%   database. Returns the result of the Sql call.
%% @end
%%--------------------------------------------------------------------
-spec sql_exec(db(), iodata(), [sql_value() | {atom() | string() | integer(), sql_value()}]) ->
       sql_result().
sql_exec(Db, SQL, Params) ->
    gen_server:call(Db, {sql_bind_and_exec, SQL, Params}).

%%--------------------------------------------------------------------
%% @doc
%%   Executes the Sql statement directly on the Db database. Returns the
%%   result of the Sql call.
%% @end
%%--------------------------------------------------------------------
-spec sql_exec_timeout(db(), iodata(), timeout()) -> sql_result().
sql_exec_timeout(Db, SQL, Timeout) ->
    gen_server:call(Db, {sql_exec, SQL}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Executes the Sql statement with parameters Params directly on the Db
%%   database. Returns the result of the Sql call.
%% @end
%%--------------------------------------------------------------------
-spec sql_exec_timeout(db(), iodata(), [sql_value() | {atom() | string() | integer(), sql_value()}], timeout()) ->
       sql_result().
sql_exec_timeout(Db, SQL, Params, Timeout) ->
    gen_server:call(Db, {sql_bind_and_exec, SQL, Params}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Executes the Sql script (consisting of semicolon-separated statements)
%%   directly on the Db database.
%%
%%   If an error happens while executing a statement, no further statements are executed.
%%
%%   The return value is the list of results of all executed statements.
%% @end
%%--------------------------------------------------------------------
-spec sql_exec_script(db(), iodata()) -> [sql_result()].
sql_exec_script(Db, SQL) ->
    gen_server:call(Db, {sql_exec_script, SQL}).

%%--------------------------------------------------------------------
%% @doc
%%   Executes the Sql statement directly on the Db database. Returns the
%%   result of the Sql call.
%% @end
%%--------------------------------------------------------------------
-spec describe_table(db(), atom()) ->
  [{column_id(), Type::string(), NotNull::boolean(), term(), PrivKey::boolean()}].
describe_table(Db, Table) when is_atom(Table) ->
    case gen_server:call(Db, {describe_table, Table}) of
      ok -> not_found;
      [_, {rows, Rows}] ->
        ToBool = fun(1) -> true; (0) -> false end,
        [{binary_to_atom(F, utf8), binary_to_list(T), ToBool(NN), D, ToBool(PK)}
          || {_, F, T, NN, D, PK} <- Rows]
    end.

%%--------------------------------------------------------------------
%% @doc
%%   Executes the Sql script (consisting of semicolon-separated statements)
%%   directly on the Db database.
%%
%%   If an error happens while executing a statement, no further statements are executed.
%%
%%   The return value is the list of results of all executed statements.
%% @end
%%--------------------------------------------------------------------
-spec sql_exec_script_timeout(db(), iodata(), timeout()) -> [sql_result()].
sql_exec_script_timeout(Db, SQL, Timeout) ->
    gen_server:call(Db, {sql_exec_script, SQL}, Timeout).

-spec prepare(db(), iodata()) -> {ok, reference()} | sqlite_error().
prepare(Db, SQL) ->
    gen_server:call(Db, {prepare, SQL}).

-spec bind(db(), reference(), sql_params()) -> sql_non_query_result().
bind(Db, Ref, Params) ->
    gen_server:call(Db, {bind, Ref, Params}).

-spec next(db(), reference()) -> tuple() | done | sqlite_error().
next(Db, Ref) ->
    gen_server:call(Db, {next, Ref}).

-spec reset(db(), reference()) -> sql_non_query_result().
reset(Db, Ref) ->
    gen_server:call(Db, {reset, Ref}).

-spec clear_bindings(db(), reference()) -> sql_non_query_result().
clear_bindings(Db, Ref) ->
    gen_server:call(Db, {clear_bindings, Ref}).

-spec finalize(db(), reference()) -> sql_non_query_result().
finalize(Db, Ref) ->
    gen_server:call(Db, {finalize, Ref}).

-spec columns(db(), reference()) -> sql_non_query_result().
columns(Db, Ref) ->
    gen_server:call(Db, {columns, Ref}).

-spec prepare_timeout(db(), iodata(), timeout()) -> {ok, reference()} | sqlite_error().
prepare_timeout(Db, SQL, Timeout) ->
    gen_server:call(Db, {prepare, SQL}, Timeout).

-spec bind_timeout(db(), reference(), sql_params(), timeout()) -> sql_non_query_result().
bind_timeout(Db, Ref, Params, Timeout) ->
    gen_server:call(Db, {bind, Ref, Params}, Timeout).

-spec next_timeout(db(), reference(), timeout()) -> tuple() | done | sqlite_error().
next_timeout(Db, Ref, Timeout) ->
    gen_server:call(Db, {next, Ref}, Timeout).

-spec reset_timeout(db(), reference(), timeout()) -> sql_non_query_result().
reset_timeout(Db, Ref, Timeout) ->
    gen_server:call(Db, {reset, Ref}, Timeout).

-spec clear_bindings_timeout(db(), reference(), timeout()) -> sql_non_query_result().
clear_bindings_timeout(Db, Ref, Timeout) ->
    gen_server:call(Db, {clear_bindings, Ref}, Timeout).

-spec finalize_timeout(db(), reference(), timeout()) -> sql_non_query_result().
finalize_timeout(Db, Ref, Timeout) ->
    gen_server:call(Db, {finalize, Ref}, Timeout).

-spec columns_timeout(db(), reference(), timeout()) -> sql_non_query_result().
columns_timeout(Db, Ref, Timeout) ->
    gen_server:call(Db, {columns, Ref}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Creates the Tbl table using TblInfo as the table structure. The
%%   table structure is a list of {column name, column type} pairs.
%%   e.g. [{name, text}, {age, integer}]
%%
%%   Returns the result of the create table call.
%% @end
%%--------------------------------------------------------------------
-spec create_table(table_id(), table_info()) -> sql_non_query_result().
create_table(Tbl, Columns) ->
    create_table(?MODULE, Tbl, Columns).

%%--------------------------------------------------------------------
%% @doc
%%   Creates the Tbl table in Db using Columns as the table structure.
%%   The table structure is a list of {column name, column type} pairs.
%%   e.g. [{name, text}, {age, integer}]
%%
%%   Returns the result of the create table call.
%% @end
%%--------------------------------------------------------------------
-spec create_table(db(), table_id(), table_info()) -> sql_non_query_result().
create_table(Db, Tbl, Columns) ->
    gen_server:call(Db, {create_table, Tbl, Columns}).

%%--------------------------------------------------------------------
%% @doc
%%   Creates the Tbl table in Db using Columns as the table structure.
%%   The table structure is a list of {column name, column type} pairs.
%%   e.g. [{name, text}, {age, integer}]
%%
%%   Returns the result of the create table call.
%% @end
%%--------------------------------------------------------------------
-spec create_table_timeout(db(), table_id(), table_info(), timeout()) -> sql_non_query_result().
create_table_timeout(Db, Tbl, Columns, Timeout) ->
    gen_server:call(Db, {create_table, Tbl, Columns}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Creates the Tbl table in Db using Columns as the table structure and
%%   Constraints as table constraints.
%%   The table structure is a list of {column name, column type} pairs.
%%   e.g. [{name, text}, {age, integer}]
%%
%%   Returns the result of the create table call.
%% @end
%%--------------------------------------------------------------------
-spec create_table(db(), table_id(), table_info(), table_constraints()) ->
          sql_non_query_result().
create_table(Db, Tbl, Columns, Constraints) ->
    gen_server:call(Db, {create_table, Tbl, Columns, Constraints}).

%%--------------------------------------------------------------------
%% @doc
%%   Creates the Tbl table in Db using Columns as the table structure and
%%   Constraints as table constraints.
%%   The table structure is a list of {column name, column type} pairs.
%%   e.g. [{name, text}, {age, integer}]
%%
%%   Returns the result of the create table call.
%% @end
%%--------------------------------------------------------------------
-spec create_table_timeout(db(), table_id(), table_info(), table_constraints(), timeout()) ->
          sql_non_query_result().
create_table_timeout(Db, Tbl, Columns, Constraints, Timeout) ->
    gen_server:call(Db, {create_table, Tbl, Columns, Constraints}, Timeout).


%%--------------------------------------------------------------------
%% @doc
%%   Add columns to table structure
%%   table structure is a list of {column name, column type} pairs.
%%   e.g. [{name, text}, {age, integer}]
%%
%%   Returns the result of the create table call.
%% @end
%%--------------------------------------------------------------------
-spec add_columns(table_id(), table_info()) -> sql_non_query_result().
add_columns(Tbl, Columns) ->
    add_columns(?MODULE, Tbl, Columns).

%%--------------------------------------------------------------------
%% @doc
%%   Add columns to table structure
%%   The table structure is a list of {column name, column type} pairs.
%%   e.g. [{name, text}, {age, integer}]
%%
%%   Returns the result of the create table call.
%% @end
%%--------------------------------------------------------------------
-spec add_columns(db(), table_id(), table_info()) -> sql_non_query_result().
add_columns(Db, Tbl, Columns) ->
    gen_server:call(Db, {add_columns, Tbl, Columns}).


%%--------------------------------------------------------------------
%% @doc
%%   Returns a list of tables.
%% @end
%%--------------------------------------------------------------------
-spec list_tables() -> [table_id()].
list_tables() ->
    list_tables(?MODULE).

%%--------------------------------------------------------------------
%% @doc
%%   Returns a list of tables for Db.
%% @end
%%--------------------------------------------------------------------
-spec list_tables(db()) -> [table_id()].
list_tables(Db) ->
    gen_server:call(Db, list_tables).

%%--------------------------------------------------------------------
%% @doc
%%   Returns a list of tables for Db.
%% @end
%%--------------------------------------------------------------------
-spec list_tables_timeout(db(), timeout()) -> [table_id()].
list_tables_timeout(Db, Timeout) ->
    gen_server:call(Db, list_tables, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%    Returns true if table `Tbl' exists.
%% @end
%%--------------------------------------------------------------------
-spec table_exists(table_id()) -> boolean().
table_exists(Tbl) ->
    table_exists(?MODULE, Tbl).

%%--------------------------------------------------------------------
%% @doc
%%    Returns true if table `Tbl' exists in `Db'.
%% @end
%%--------------------------------------------------------------------
-spec table_exists(db(), table_id()) -> boolean().
table_exists(Db, Tbl) when is_atom(Db), is_atom(Tbl) ->
    table_exists(Db, atom_to_list(Tbl));
table_exists(Db, Tbl) when is_atom(Db), is_list(Tbl) ->
    table_exists(Db, Tbl, infinity).

-spec table_exists(db(), table_id(), timeout()) -> boolean().
table_exists(Db, Tbl, Timeout) when is_atom(Db), is_list(Tbl) ->
    gen_server:call(Db, {table_exists, Tbl}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%    Returns table schema for Tbl.
%% @end
%%--------------------------------------------------------------------
-spec table_info(table_id()) -> table_info().
table_info(Tbl) ->
    table_info(?MODULE, Tbl).

%%--------------------------------------------------------------------
%% @doc
%%   Returns table schema for Tbl in Db.
%% @end
%%--------------------------------------------------------------------
-spec table_info(db(), table_id()) -> table_info().
table_info(Db, Tbl) ->
    gen_server:call(Db, {table_info, Tbl}).

%%--------------------------------------------------------------------
%% @doc
%%   Returns table schema for Tbl in Db.
%% @end
%%--------------------------------------------------------------------
-spec table_info_timeout(db(), table_id(), timeout()) -> table_info().
table_info_timeout(Db, Tbl, Timeout) ->
    gen_server:call(Db, {table_info, Tbl}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Write Data into Tbl table. Value must be of the same type as
%%   determined from table_info/2.
%% @end
%%--------------------------------------------------------------------
-spec write(table_id(), [{column_id(), sql_value()}]) -> sql_non_query_result().
write(Tbl, KVs) when is_tuple(KVs) andalso
                      (tuple_size(KVs)==2 orelse tuple_size(KVs)==3) ->
    write(Tbl, [KVs]);
write(Tbl, KVs) ->
    write(?MODULE, Tbl, KVs).

%%--------------------------------------------------------------------
%% @doc
%%   Write Data into Tbl table in Db database. Value must be of the
%%   same type as determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec write(db(), table_id(), [{column_id(), sql_value()}]) -> sql_non_query_result().
write(Db, Tbl, Data) ->
    gen_server:call(Db, {write, Tbl, Data}).

%%--------------------------------------------------------------------
%% @doc
%%   Write Data into Tbl table in Db database. Value must be of the
%%   same type as determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec write_timeout(db(), table_id(), [{column_id(), sql_value()}], timeout()) ->
          sql_non_query_result().
write_timeout(Db, Tbl, Data, Timeout) ->
    gen_server:call(Db, {write, Tbl, Data}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Write all records in Data into table Tbl. Value must be of the
%%   same type as determined from table_info/2.
%% @end
%%--------------------------------------------------------------------
-spec write_many(table_id(), [[{column_id(), sql_value()}]]) -> [sql_result()].
write_many(Tbl, Data) ->
    write_many(?MODULE, Tbl, Data).

%%--------------------------------------------------------------------
%% @doc
%%   Write all records in Data into table Tbl in database Db. Value
%%   must be of the same type as determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec write_many(db(), table_id(), [[{column_id(), sql_value()}]]) -> [sql_result()].
write_many(Db, Tbl, Data) ->
    gen_server:call(Db, {write_many, Tbl, Data}).

%%--------------------------------------------------------------------
%% @doc
%%   Write all records in Data into table Tbl in database Db. Value
%%   must be of the same type as determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec write_many_timeout(db(), table_id(), [[{column_id(), sql_value()}]], timeout()) ->
          [sql_result()].
write_many_timeout(Db, Tbl, Data, Timeout) ->
    gen_server:call(Db, {write_many, Tbl, Data}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%    Updates rows into Tbl table such that the Value matches the
%%    value in Key with Data.
%% @end
%%--------------------------------------------------------------------
-spec update(table_id(), {column_id(), sql_value()}, [{column_id(), sql_value()}]) ->
          sql_non_query_result().
update(Tbl, {Key, Value}, Data) ->
    update(Tbl, [{Key, Value}], Data);
update(Tbl, [KV|_]=KVs, Data) when is_tuple(KV) andalso
                                   (tuple_size(KV)==2 orelse tuple_size(KV)==3) ->
    update(?MODULE, Tbl, KVs, Data).

%%--------------------------------------------------------------------
%% @doc
%%    Updates rows into Tbl table in Db database such that the Value
%%    matches the value in Key with Data.
%% @end
%%--------------------------------------------------------------------
-spec update(db(), table_id(), {column_id(), sql_value()}|
                              [{column_id(), sql_value()}],
             [{column_id(), sql_value()}]) -> sql_non_query_result().
update(Db, Tbl, {_Key, _Value}=KV, Data) ->
    update(Db, Tbl, [KV], Data);
update(Db, Tbl, [KV|_]=KVs, Data) when is_tuple(KV) andalso
                                       (tuple_size(KV)==2 orelse tuple_size(KV)==3) ->
    gen_server:call(Db, {update, Tbl, KVs, Data}).

%%--------------------------------------------------------------------
%% @doc
%%    Updates rows into Tbl table in Db database such that the Value
%%    matches the value in Key with Data.
%% @end
%%--------------------------------------------------------------------
-spec update_timeout(db(), table_id(), {column_id(), sql_value()}|
                                      [{column_id(), sql_value()}],
                     [{column_id(), sql_value()}], timeout()) -> sql_non_query_result().
update_timeout(Db, Tbl, {Key, Value}, Data, Timeout) ->
    update_timeout(Db, Tbl, [{Key, Value}], Data, Timeout);
update_timeout(Db, Tbl, [KV|_]=KVs, Data, Timeout)
    when is_tuple(KV) andalso
        (tuple_size(KV)==2 orelse tuple_size(KV)==3) ->
    gen_server:call(Db, {update, Tbl, KVs, Data}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Reads all rows from Table in Db.
%% @end
%%--------------------------------------------------------------------
-spec read_all(db(), table_id()) -> sql_result().
read_all(Db, Tbl) ->
    gen_server:call(Db, {read, Tbl}).

%%--------------------------------------------------------------------
%% @doc
%%   Reads all rows from Table in Db.
%% @end
%%--------------------------------------------------------------------
-spec read_all_timeout(db(), table_id(), timeout()) -> sql_result().
read_all_timeout(Db, Tbl, Timeout) ->
    gen_server:call(Db, {read, Tbl}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Reads Columns in all rows from Table in Db.
%% @end
%%--------------------------------------------------------------------
-spec read_all(db(), table_id(), [column_id()]) -> sql_result().
read_all(Db, Tbl, all) ->
    gen_server:call(Db, {read, Tbl, all});
read_all(Db, Tbl, [C|_] = Columns) when is_atom(C); is_list(C); is_binary(C) ->
    gen_server:call(Db, {read, Tbl, Columns}).

%%--------------------------------------------------------------------
%% @doc
%%   Reads Columns in all rows from Table in Db.
%% @end
%%--------------------------------------------------------------------
-spec read_all_timeout(db(), table_id(), all|[column_id()], timeout()) -> sql_result().
read_all_timeout(Db, Tbl, Columns, Timeout) ->
    gen_server:call(Db, {read, Tbl, Columns}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Reads a row from Tbl table such that the Value matches the
%%   value in Column. Value must have the same type as determined
%%   from table_info/2.
%% @end
%%--------------------------------------------------------------------
-spec read(table_id(), {column_id(), sql_value()}|
                      [{column_id(), sql_value()}]|
                      [{column_id(), Op::'>'|'<'|'>='|'<='|'!=', sql_value()}]) ->
            sql_result().
read(Tbl, KV) when is_tuple(KV) andalso
                   (tuple_size(KV)==2 orelse tuple_size(KV)==3)->
    read(?MODULE, Tbl, KV, all);
read(Tbl, [KV|_] = Key) when is_tuple(KV) andalso
                             (tuple_size(KV)==2 orelse tuple_size(KV)==3) ->
    read(?MODULE, Tbl, Key, all).

%%--------------------------------------------------------------------
%% @doc
%%   Reads a row from Tbl table in Db database such that the Value
%%   matches the value in Column. ColValue must have the same type
%%   as determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec read(db(), table_id(), {column_id(), sql_value()}|
                      [{column_id(), sql_value()}]|
                      [{column_id(), Op::'>'|'<'|'>='|'<='|'!=', sql_value()}]) ->
           sql_result().
read(Db, Tbl, KV) when is_tuple(KV) andalso
                      (tuple_size(KV)==2 orelse tuple_size(KV)==3)->
    read(Db, Tbl, [KV]);
read(Db, Tbl, [KV|_]=CV) when is_tuple(KV) andalso
                              (tuple_size(KV)==2 orelse tuple_size(KV)==3) ->
    gen_server:call(Db, {read, Tbl, CV, all}).

%%--------------------------------------------------------------------
%% @doc
%%    Reads a row from Tbl table in Db database such that the Value
%%    matches the value in Column. Value must have the same type as
%%    determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec read(db(), table_id(), {column_id(), sql_value()}|
                            [{column_id(), sql_value()}]|
                            [{column_id(), Op::'>'|'<'|'>='|'<='|'!=', sql_value()}],
                            all|[column_id()]) ->
        sql_result().
read(Db, Tbl, KV, Columns) when is_tuple(KV) andalso
                                (tuple_size(KV)==2 orelse tuple_size(KV)==3)->
    read(Db, Tbl, [KV], Columns);
read(Db, Tbl, [KV|_]=CV, Columns) when is_tuple(KV) andalso
                                       (tuple_size(KV)==2 orelse tuple_size(KV)==3) ->
    gen_server:call(Db, {read, Tbl, CV, Columns}).

%%--------------------------------------------------------------------
%% @doc
%%   Reads a row from Tbl table in Db database such that the Value
%%   matches the value in Column. ColValue must have the same type
%%   as determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec read_timeout(db(), table_id(), {column_id(), sql_value()}|
                                    [{column_id(), sql_value()}]|
                                    [{column_id(), Op::'>'|'<'|'>='|'<='|'!=', sql_value()}],
                                    timeout()) ->
        sql_result().
read_timeout(Db, Tbl, {_Column, _Value}=KV, Timeout) ->
    gen_server:call(Db, {read, Tbl, [KV]}, Timeout);
read_timeout(Db, Tbl, [KV|_]=CV, Timeout) when is_tuple(KV) andalso
                                               (tuple_size(KV)==2 orelse tuple_size(KV)==3) ->
    gen_server:call(Db, {read, Tbl, CV}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%    Reads a row from Tbl table in Db database such that the Value
%%    matches the value in Column. Value must have the same type as
%%    determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec read_timeout(db(), table_id(), {column_id(), sql_value()}|
                                    [{column_id(), sql_value()}]|
                                    [{column_id(), Op::'>'|'<'|'>='|'<='|'!=', sql_value()}],
                                    all|[column_id()], timeout()) ->
        sql_result().
read_timeout(Db, Tbl, {_Col, _Value}=CV, Columns, Timeout) ->
    gen_server:call(Db, {read, Tbl, [CV], Columns}, Timeout);
read_timeout(Db, Tbl, [KV|_]=CV, Columns, Timeout) when is_tuple(KV)
                                                      , (tuple_size(KV)==2 orelse tuple_size(KV)==3) ->
    gen_server:call(Db, {read, Tbl, CV, Columns}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Delete a row from Tbl table in Db database such that the Value
%%   matches the value in Column.
%%   Value must have the same type as determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec delete(table_id(), {column_id(), sql_value()}|
                        [{column_id(), sql_value()}]) -> sql_non_query_result().
delete(Tbl, Key) ->
    delete(?MODULE, Tbl, Key).

%%--------------------------------------------------------------------
%% @doc
%%   Delete a row from Tbl table in Db database such that the Value
%%   matches the value in Column.
%%   Value must have the same type as determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec delete_timeout(db(), table_id(), {column_id(), sql_value()}|
                                      [{column_id(), sql_value()}],
                     timeout()) -> sql_non_query_result().
delete_timeout(Db, Tbl, Key, Timeout) ->
    gen_server:call(Db, {delete, Tbl, Key}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Delete a row from Tbl table in Db database such that the Value
%%   matches the value in Column.
%%   Value must have the same type as determined from table_info/3.
%% @end
%%--------------------------------------------------------------------
-spec delete(db(), table_id(), {column_id(), sql_value()}|
                              [{column_id(), sql_value()}]) -> sql_non_query_result().
delete(Db, Tbl, {_Key, _Value}=KV) ->
    delete(Db, Tbl, [KV]);
delete(Db, Tbl, [{_,_}|_] = Key) ->
    gen_server:call(Db, {delete, Tbl, Key}).

%%--------------------------------------------------------------------
%% @doc
%%   Drop the table Tbl.
%% @end
%%--------------------------------------------------------------------
-spec drop_table(table_id()) -> sql_non_query_result().
drop_table(Tbl) ->
    drop_table(?MODULE, Tbl).

%%--------------------------------------------------------------------
%% @doc
%%   Drop the table Tbl from Db database.
%% @end
%%--------------------------------------------------------------------
-spec drop_table(db(), table_id()) -> sql_non_query_result().
drop_table(Db, Tbl) ->
    gen_server:call(Db, {drop_table, Tbl}).

%%--------------------------------------------------------------------
%% @doc
%%   Drop the table Tbl from Db database.
%% @end
%%--------------------------------------------------------------------
-spec drop_table_timeout(db(), table_id(), timeout()) -> sql_non_query_result().
drop_table_timeout(Db, Tbl, Timeout) ->
    gen_server:call(Db, {drop_table, Tbl}, Timeout).

%%--------------------------------------------------------------------
%% @doc
%%   Vacuum the default database.
%% @end
%%--------------------------------------------------------------------
-spec vacuum() -> sql_non_query_result().
vacuum() ->
    gen_server:call(?MODULE, vacuum).

%%--------------------------------------------------------------------
%% @doc
%%   Vacuum the Db database.
%% @end
%%--------------------------------------------------------------------
-spec vacuum(db()) -> sql_non_query_result().
vacuum(Db) ->
    gen_server:call(Db, vacuum).

%%--------------------------------------------------------------------
%% @doc
%%   Vacuum the Db database.
%% @end
%%--------------------------------------------------------------------
-spec vacuum_timeout(db(), timeout()) -> sql_non_query_result().
vacuum_timeout(Db, Timeout) ->
    gen_server:call(Db, vacuum, Timeout).

%% %%--------------------------------------------------------------------
%% %% @doc
%% %%   Creates function under name FunctionName.
%% %%
%% %% @end
%% %%--------------------------------------------------------------------
%% -spec create_function(db(), atom(), function()) -> any().
%% create_function(Db, FunctionName, Function) ->
%%     gen_server:call(Db, {create_function, FunctionName, Function}).

%%--------------------------------------------------------------------
%% @doc
%%    Converts an Erlang term to an SQL string.
%%    Currently supports integers, floats, 'null' atom, and iodata
%%    (binaries and iolists) which are treated as SQL strings.
%%
%%    Note that it opens opportunity for injection if an iolist includes
%%    single quotes! Replace all single quotes (') with '' manually, or
%%    use value_to_sql/1 if you are not sure if your strings contain
%%    single quotes (e.g. can be entered by users).
%%
%%    Reexported from sqlite3_lib:value_to_sql/1 for user convenience.
%% @end
%%--------------------------------------------------------------------
-spec value_to_sql_unsafe(sql_value()) -> iolist().
value_to_sql_unsafe(X) -> sqlite3_lib:value_to_sql_unsafe(X).

%%--------------------------------------------------------------------
%% @doc
%%    Converts an Erlang term to an SQL string.
%%    Currently supports integers, floats, 'null' atom, and iodata
%%    (binaries and iolists) which are treated as SQL strings.
%%
%%    All single quotes (') will be replaced with ''.
%%
%%    Reexported from sqlite3_lib:value_to_sql/1 for user convenience.
%% @end
%%--------------------------------------------------------------------
-spec value_to_sql(sql_value()) -> iolist().
value_to_sql(X) -> sqlite3_lib:value_to_sql(X).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Initiates the server
%% @end
%% @hidden
%%--------------------------------------------------------------------

% -type init_return() :: {'ok', tuple()} | {'ok', tuple(), integer()} | 'ignore' | {'stop', any()}.

-spec init([any()]) -> {'ok', #state{}} | {'stop', string()}.
init(Options) ->
    PrivDir = get_priv_dir(),
    Driver  = driver_name(),
    case erl_ddll:load(PrivDir, Driver) of
        ok ->
            do_init(Driver, Options);
        {error, permanent} -> %% already loaded!
            try
                do_init(Driver, Options)
            catch throw:Reason ->
                {stop, Reason}
            end;
        {error, Error} ->
            Msg = io_lib:format("Error loading ~s: ~s",
                                [Driver, erl_ddll:format_error(Error)]),
            {stop, lists:flatten(Msg)}
    end.

-spec do_init(string(), [any()]) -> {'ok', #state{}} | {'stop', string()}.
do_init(DriverName, Options) ->
    {DbFile, Opts} =
        case lists:keytake(file, 1, Options) of
            {value, {file, F}, Rest} -> {F,  Rest};
            false                    -> {"", Options}
        end,
    Port = open_port({spawn, create_port_cmd(DriverName, DbFile, Opts)}, [binary]),
    receive
        {Port, ok} ->
            {ok, #state{port = Port, ops = Options}};
        {Port, {error, Code, Message}} ->
            Msg = io_lib:format("Error opening DB file ~p: code ~B, message '~s'",
                                [DbFile, Code, Message]),
            {stop, lists:flatten(Msg)}
    end.

%%--------------------------------------------------------------------
%% @doc Handling call messages
%% @end
%% @hidden
%%--------------------------------------------------------------------

%% -type handle_call_return() :: {reply, any(), tuple()} | {reply, any(), tuple(), integer()} |
%%       {noreply, tuple()} | {noreply, tuple(), integer()} |
%%       {stop, any(), any(), tuple()} | {stop, any(), tuple()}.

-spec handle_call(any(), pid(), #state{}) -> {'reply', any(), #state{}} | {'stop', 'normal', 'ok', #state{}}.
handle_call(close, _From, State) ->
    {stop, normal, _Reply = ok, State};
handle_call(list_tables, _From, State) ->
    SQL = "select name, sql from sqlite_master where type='table';",
    case do_sql_exec(SQL, State) of
        Data when is_list(Data)->
            TableList = proplists:get_value(rows, Data),
            TableNames = [cast_table_name(Name, SQLx) || {Name,SQLx} <- TableList],
            {reply, TableNames, State};
        {error, _Code, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call({table_exists, _Tbl}=Cmd, _From, #state{port = Port} = State) ->
    case exec(Port, Cmd) of
        Result when is_boolean(Result)->
            {reply, Result, State};
        {error, _Code, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call({table_info, Tbl}, _From, State) when is_atom(Tbl) ->
    % make sure we only get table info.
    SQL = io_lib:format("select sql from sqlite_master where tbl_name = '~s' and type='table';", [to_list(Tbl)]),
    case do_sql_exec(SQL, State) of
        Data when is_list(Data)->
            TableSql = proplists:get_value(rows, Data),
            case TableSql of
                [{Info}] ->
                    ColumnList = parse_table_info(Info),
                    {reply, ColumnList, State};
                [] ->
                    {reply, table_does_not_exist, State}
            end;
        {error, _Code, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call({table_info, _NotAnAtom}, _From, State) ->
    {reply, {error, badarg}, State};
handle_call({create_function, FunctionName, Function}, _From, #state{port = Port} = State) ->
    Reply = exec(Port, {create_function, FunctionName, Function}),
    {reply, Reply, State};
handle_call({sql_exec, SQL}, _From, State) ->
    do_handle_call_sql_exec(SQL, State);
handle_call({sql_bind_and_exec, SQL, Params}, _From, State) ->
    Reply = do_sql_bind_and_exec(SQL, Params, State),
    {reply, Reply, State};
handle_call({sql_exec_script, SQL}, _From, State) ->
    Reply = do_sql_exec_script(SQL, State),
    {reply, Reply, State};
handle_call({add_columns, Tbl, Columns}, _From, State) ->
    try sqlite3_lib:add_columns_sql(Tbl, Columns) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({create_table, Tbl, Columns}, _From, State) ->
    try sqlite3_lib:create_table_sql(Tbl, Columns) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({create_table, Tbl, Columns, Constraints}, _From, State) ->
    try sqlite3_lib:create_table_sql(Tbl, Columns, Constraints) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({update, Tbl, KVs, Data}, _From, State) ->
    try sqlite3_lib:update_sql(Tbl, KVs, Data) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({write, Tbl, Data}, _From, State) ->
    % insert into t1 (data,num) values ('This is sample data',3);
    try sqlite3_lib:write_sql(Tbl, Data) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({write_many, Tbl, DataList}, _From, State) ->
    SQLScript = ["SAVEPOINT 'erlang-sqlite3-write_many';",
                 [sqlite3_lib:write_sql(Tbl, Data) || Data <- DataList],
                 "RELEASE SAVEPOINT 'erlang-sqlite3-write_many';"],
    Reply = do_sql_exec_script(SQLScript, State),
    {reply, Reply, State};
handle_call({read, Tbl}, _From, State) ->
    % select * from  Tbl where Key = Value;
    try sqlite3_lib:read_sql(Tbl) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({read, Tbl, Columns}, _From, State) ->
    try sqlite3_lib:read_sql(Tbl, Columns) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({read, Tbl, KVs, Columns}, _From, State) ->
    try sqlite3_lib:read_sql(Tbl, KVs, Columns) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({delete, Tbl, KVs}, _From, State) ->
    % delete from Tbl where Key = Value;
    try sqlite3_lib:delete_sql(Tbl, KVs) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({drop_table, Tbl}, _From, State) ->
    try sqlite3_lib:drop_table_sql(Tbl) of
        SQL -> do_handle_call_sql_exec(SQL, State)
    catch
        _:Exception ->
            {reply, {error, Exception}, State}
    end;
handle_call({prepare, SQL}, _From, State = #state{port = Port, refs = Refs}) ->
    case exec(Port, {prepare, SQL}) of
        Index when is_integer(Index) ->
            Ref = erlang:make_ref(),
            Reply = {ok, Ref},
            NewState = State#state{refs = dict:store(Ref, Index, Refs)};
        Error ->
            Reply = Error,
            NewState = State
    end,
    {reply, Reply, NewState};
handle_call({bind, Ref, Params}, _From, State = #state{port = Port, refs = Refs}) ->
    Reply = case dict:find(Ref, Refs) of
                {ok, Index} ->
                    exec(Port, {bind, Index, Params});
                error ->
                    {error, badarg}
            end,
    {reply, Reply, State};
handle_call({finalize, Ref}, _From, State = #state{port = Port, refs = Refs}) ->
    case dict:find(Ref, Refs) of
        {ok, Index} ->
            case exec(Port, {finalize, Index}) of
                ok ->
                    Reply = ok,
                    NewState = State#state{refs = dict:erase(Ref, Refs)};
                Error ->
                    Reply = Error,
                    NewState = State
            end;
        error ->
            Reply = {error, badarg},
            NewState = State
    end,
    {reply, Reply, NewState};
handle_call({enable_load_extension, _Value} = Payload, _From, State = #state{port =
        Port, refs = _Refs}) ->
    Reply = exec(Port, Payload),
    {reply, Reply, State};
handle_call(changes = Payload, _From, State = #state{port = Port, refs = _Refs}) ->
    Reply = exec(Port, Payload),
    {reply, Reply, State};
handle_call(filename = Payload, _From, State = #state{port = Port, refs = _Refs}) ->
    Reply = exec(Port, Payload),
    {reply, Reply, State};
handle_call({describe_table, Table}, _From, State) ->
    SQL = sqlite3_lib:describe_table(Table),
    do_handle_call_sql_exec(SQL, State);
handle_call({Cmd, Ref}, _From, State = #state{port = Port, refs = Refs}) ->
    Reply = case dict:find(Ref, Refs) of
                {ok, Index} ->
                    exec(Port, {Cmd, Index});
                error ->
                    {error, badarg}
            end,
    {reply, Reply, State};
handle_call(vacuum, _From, State) ->
    SQL = "VACUUM;",
    do_handle_call_sql_exec(SQL, State);
handle_call(_Request, _From, State) ->
    Reply = unknown_request,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @doc Handling cast messages
%% @end
%% @hidden
%%--------------------------------------------------------------------

%% -type handle_cast_return() :: {noreply, tuple()} | {noreply, tuple(), integer()} |
%%       {stop, any(), tuple()}.

-spec handle_cast(any(), #state{}) -> {'noreply', #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc Handling all non call/cast messages
%% @end
%% @hidden
%%--------------------------------------------------------------------
-spec handle_info(any(), #state{}) -> {'noreply', #state{}}.
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%% @end
%% @hidden
%%--------------------------------------------------------------------
-spec terminate(atom(), tuple()) -> term().
terminate(_Reason, #state{port = Port}) ->
    case Port of
        undefined ->
            pass;
        _ ->
            port_close(Port)
    end,
    Driver = driver_name(),
    case erl_ddll:unload(Driver) of
        ok ->
            ok;
        {error, permanent} ->
            %% Older Erlang versions mark any driver using driver_async
            %% as permanent
            ok;
        {error, ErrorDesc} ->
            error_logger:error_msg("Error unloading ~s driver: ~s~n",
                                   [Driver, erl_ddll:format_error(ErrorDesc)])
    end,
    ok.

%%--------------------------------------------------------------------
%% @doc Convert process state when code is changed
%% @end
%% @hidden
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

get_priv_dir() ->
    case code:priv_dir(sqlite3) of
        {error, bad_name} ->
            %% application isn't in path, fall back
            {?MODULE, _, FileName} = code:get_object_code(?MODULE),
            filename:join(filename:dirname(FileName), "../priv");
        Dir ->
            Dir
    end.

driver_name() ->
    Target = case os:type() of
                {win32, _}   -> ".win";
                {unix,linux} -> ".linux";
                _            -> ""
              end,
    Arch   = case erlang:system_info(wordsize) of
                4 -> ".x86";
                _ -> ".x64"
             end,
    atom_to_list(?DRIVER_NAME) ++ Target ++ Arch.

-define(SQL_EXEC_COMMAND,          2).
-define(SQL_CREATE_FUNCTION,       3).
-define(SQL_BIND_AND_EXEC_COMMAND, 4).
-define(PREPARE,                   5).
-define(PREPARED_BIND,             6).
-define(PREPARED_STEP,             7).
-define(PREPARED_RESET,            8).
-define(PREPARED_CLEAR_BINDINGS,   9).
-define(PREPARED_FINALIZE,        10).
-define(PREPARED_COLUMNS,         11).
-define(SQL_EXEC_SCRIPT,          12).
-define(ENABLE_LOAD_EXTENSION,    13).
-define(CHANGES,                  14).
-define(DB_FILENAME,              15).
-define(TABLE_EXISTS,             16).

create_port_cmd(DriverName, DbFile, Options) ->
    Opts = case [readonly, readwrite] -- Options of
              [readonly, readwrite] -> [create, readwrite | Options];
              _                     -> Options
           end,
    DriverName ++ " " ++ DbFile ++ lists:append(opts(Opts)).

%% Custom option
opts([debug           | T]) -> [" -d"             | opts(T)];
%% sqlite3_open_v2() options
opts([readonly        | T]) -> [" -ro"            | opts(T)];
opts([readwrite       | T]) -> [" -rw"            | opts(T)];
opts([create          | T]) -> [" -create"        | opts(T)];
opts([delete_on_close | T]) -> [" -doc"           | opts(T)];
opts([exclusive       | T]) -> [" -exclusive"     | opts(T)];
opts([auto_proxy      | T]) -> [" -auto-proxy"    | opts(T)];
opts([uri             | T]) -> [" -uri"           | opts(T)];
opts([memory          | T]) -> [" -m"             | opts(T)];
opts([main_db         | T]) -> [" -main-db"       | opts(T)];
opts([temp_db         | T]) -> [" -temp-db"       | opts(T)];
opts([transient       | T]) -> [" -transient-db"  | opts(T)];
opts([main_journal    | T]) -> [" -main-journal"  | opts(T)];
opts([temp_journal    | T]) -> [" -temp-journal"  | opts(T)];
opts([master_journal  | T]) -> [" -master-journal"| opts(T)];
opts([no_mutex        | T]) -> [" -no-mutex"      | opts(T)];
opts([full_mutex      | T]) -> [" -full-mutex"    | opts(T)];
opts([shared_cache    | T]) -> [" -shared-cache"  | opts(T)];
opts([private_cache   | T]) -> [" -private-cache" | opts(T)];
opts([wal             | T]) -> [" -wal"           | opts(T)];
opts([Other           | _]) -> throw({invalid_option, Other});
opts([]) ->
    [].

do_handle_call_sql_exec(SQL, State) ->
    Reply = do_sql_exec(SQL, State),
    {reply, Reply, State}.

do_sql_exec(SQL, #state{port = Port}) ->
    ?dbgF("SQL: ~s~n", [SQL]),
    exec(Port, {sql_exec, SQL}).

do_sql_bind_and_exec(SQL, Params, #state{port = Port}) ->
    ?dbgF("SQL: ~s; Parameters: ~p~n", [SQL, Params]),
    exec(Port, {sql_bind_and_exec, SQL, Params}).

do_sql_exec_script(SQL, #state{port = Port}) ->
    ?dbgF("SQL: ~s~n", [SQL]),
    exec(Port, {sql_exec_script, SQL}).

exec(_Port, {create_function, _FunctionName, _Function}) ->
    error_logger:error_report([{application, sqlite3}, "NOT IMPL YET"]);
%port_control(Port, ?SQL_CREATE_FUNCTION, list_to_binary(Cmd)),
%wait_result(Port);
exec(Port, {sql_exec, SQL}) ->
    port_control(Port, ?SQL_EXEC_COMMAND, SQL),
    wait_result(Port);
exec(Port, {sql_bind_and_exec, SQL, Params}) ->
    Bin = term_to_binary({iolist_to_binary(SQL), Params}),
    port_control(Port, ?SQL_BIND_AND_EXEC_COMMAND, Bin),
    wait_result(Port);
exec(Port, {sql_exec_script, SQL}) ->
    port_control(Port, ?SQL_EXEC_SCRIPT, SQL),
    wait_result(Port);
exec(Port, {prepare, SQL}) ->
    port_control(Port, ?PREPARE, SQL),
    wait_result(Port);
exec(Port, {bind, Index, Params}) ->
    Bin = term_to_binary({Index, Params}),
    port_control(Port, ?PREPARED_BIND, Bin),
    wait_result(Port);
exec(Port, {enable_load_extension, Value}) ->
    % Payload is 1 if enabling extension loading,
    % 0 if disabling
    Payload = case Value of
        true -> 1;
        _ when is_integer(Value) -> Value;
        false -> 0;
        _ -> 0
    end,
    port_control(Port, ?ENABLE_LOAD_EXTENSION, <<Payload>>),
    wait_result(Port);
exec(Port, changes) ->
    port_control(Port, ?CHANGES, <<"">>),
    wait_result(Port);
exec(Port, {table_exists, Tbl}) ->
    port_control(Port, ?TABLE_EXISTS, Tbl),
    wait_result(Port);
exec(Port, filename) ->
    port_control(Port, ?DB_FILENAME, <<"">>),
    wait_result(Port);
exec(Port, {Cmd, Index}) when is_integer(Index) ->
    CmdCode = case Cmd of
                  next -> ?PREPARED_STEP;
                  reset -> ?PREPARED_RESET;
                  clear_bindings -> ?PREPARED_CLEAR_BINDINGS;
                  finalize -> ?PREPARED_FINALIZE;
                  columns -> ?PREPARED_COLUMNS
              end,
    Bin = term_to_binary(Index),
    port_control(Port, CmdCode, Bin),
    wait_result(Port).

wait_result(Port) ->
    receive
        {Port, Reply} ->
            Reply;
        {'EXIT', Port, Reason} ->
            {error, {port_exit, Reason}};
        Other when is_tuple(Other), element(1, Other) =/= '$gen_call', element(1, Other) =/= '$gen_cast' ->
            Other
    end.

parse_table_info(Info) ->
    {StartPos,_} = binary:match(Info, <<"(">>),
    BodyFun = fun
        G(B, I) when I >=0 ->
            case binary:at(B, I) of
                $) -> binary:part(B, StartPos+1, I-StartPos-1);
                _  -> G(B, I-1)
            end;
        G(_, _) ->
            <<>>
    end,
    Info1 = BodyFun(Info, byte_size(Info)-1),
    Info2 = re:replace(Info1, <<"CHECK \\('(bin|lst|am)'='(bin|lst|am)'\\)\\)">>, <<"">>, [global, {return, binary}]),
    Info3 = [re:replace(I, <<"[\r\n]">>, <<>>, [global, {return, binary}])
              || I <- re:split(Info2, <<",[\r\n]">>, [trim, {return, binary}, notempty])],
    
    Match = [
        {<<"\\s*CONSTRAINT\\s+(\\w+)\\s+PRIMARY KEY\\s+\\(\\s*([^\\)]+)\\)">>,
            fun
                ([_Name, ColList], Cols) ->
                    L = [case string:tokens(I, " \t") of
                           [C]   -> {list_to_atom(C), [primary_key]};
                           [C|T] ->
                               case build_primary_key_constraint(T) of
                                  {primary_key, _}       -> {list_to_atom(C), [primary_key]};
                                  {{primary_key,Opts},_} -> {list_to_atom(C), [{primary_key,Opts}]}
                               end
                         end || I <- string:tokens(ColList, ",")],
                    lists:foldl(fun({Col, Opts}, Acc) ->
                        case lists:keyfind(Col, 1, Acc) of
                            false ->
                                io:format("Processing constraint: ~w not found in ~p\n", [Col, Acc]),
                                Acc;
                            {Col, Tp, ColOpts} ->
                                lists:keyreplace(Col, 1, Acc, {Col, Tp, Opts ++ ColOpts})
                        end
                    end, Cols, L)
            end},
        {<<"^\\s+(\\w+)\\s+(\\w+)\\s+\\((\\d+), *(\\d+)\\)(?:\\s+(NULL|NOT NULL))?(.*)">>,
            fun
                ([Col, Type, D1, D2, Nullable, []], Cols) ->
                    [{list_to_atom(Col), sqlite3_lib:col_type_to_atom(Type),
                        null(Nullable) ++ [{size, list_to_integer(D1)}, {precision, list_to_integer(D2)}]} | Cols];
                ([Col, Type, D1, D2, Nullable, Constraint], Cols) ->
                    [{list_to_atom(Col), sqlite3_lib:col_type_to_atom(Type),
                        null(Nullable) ++ [{size, list_to_integer(D1)}, {precision, list_to_integer(D2)}
                                           | constraint(Constraint)]} | Cols]
            end},
        {<<"^\\s+(\\w+)\\s+(\\w+)\\s+\\((\\d+)\\)(?:\\s+(NULL|NOT NULL))?(.*)">>,
            fun
                ([Col, Type, D1, Nullable, []], Cols) ->
                    [{list_to_atom(Col), sqlite3_lib:col_type_to_atom(Type),
                        null(Nullable) ++ [{size, list_to_integer(D1)}]} | Cols];
                ([Col, Type, D1, Nullable, Constraint], Cols) ->
                    [{list_to_atom(Col), sqlite3_lib:col_type_to_atom(Type),
                        null(Nullable) ++ [{size, list_to_integer(D1)} | constraint(Constraint)]} | Cols]
            end},
        {<<"^\\s+(\\w+)\\s+(\\w+)(?:\\s+(NULL|NOT NULL))?(.*)">>,
            fun
                ([Col, Type, Nullable, []], Cols) ->
                    [{list_to_atom(Col), sqlite3_lib:col_type_to_atom(Type), null(Nullable)} | Cols];
                ([Col, Type, Nullable, Constraint], Cols) ->
                    [{list_to_atom(Col), sqlite3_lib:col_type_to_atom(Type), null(Nullable) ++ constraint(Constraint)} | Cols]
            end}
    ],
    lists:reverse(
        lists:foldl(fun(Row, Cols) ->
            case match(Row, Match, Cols) of
                false ->
                    Cols;
                NewCols ->
                    NewCols
            end
        end, [], Info3)).

match(_Row, [], _Cols) ->
    false;
match(Row, [{Re, Fun}|T], Cols) ->
    case re:run(Row, Re, [{capture, all, list}]) of
        {match, [_|Fields]} ->
            Fun(Fields, Cols);
        nomatch ->
            match(Row, T, Cols)
    end.

null("NOT NULL") -> [not_null];
null("not null") -> [not_null];
null(_)          -> [].

constraint(Constraint) ->
    build_constraints(string:tokens(Constraint, " ")).

%% TODO conflict-clause parsing
build_constraints([]) -> [];
build_constraints([Primary, Key | Tail]) when Primary=="PRIMARY", Key=="KEY"
                                            ; Primary=="primary", Key=="key" ->
    {Constraint, Rest} = build_primary_key_constraint(Tail),
    [Constraint | build_constraints(Rest)];
build_constraints([Unique | Tail]) when Unique=="UNIQUE"; Unique=="unique"->
    [unique | build_constraints(Tail)];
build_constraints([Default, DefaultValue | Tail]) when Default=="DEFAULT"; Default=="default" ->
    case re:run(DefaultValue, "^\\((.*)\\)$", [{capture, all, list}]) of
        {match, [_, Value]} ->
            [{default, Value} | build_constraints(Tail)];
        nomatch ->
            [{default, sqlite3_lib:sql_to_value(DefaultValue)} | build_constraints(Tail)]
    end;
build_constraints(UnknownConstraints) ->
    io:format("Constraints: ~p\n", [UnknownConstraints]),
    [{cant_parse_constraints, string:join(UnknownConstraints, " ")}].

build_primary_key_constraint(Tokens) -> build_primary_key_constraint(Tokens, []).

build_primary_key_constraint(["ASC" | Rest], Acc) ->
    build_primary_key_constraint(Rest, [asc | Acc]);
build_primary_key_constraint(["DESC" | Rest], Acc) ->
    build_primary_key_constraint(Rest, [desc | Acc]);
build_primary_key_constraint(["AUTOINCREMENT" | Rest], Acc) ->
    build_primary_key_constraint(Rest, [autoincrement | Acc]);
build_primary_key_constraint(Tail, []) ->
    {primary_key, Tail};
build_primary_key_constraint(Tail, Acc) ->
    {{primary_key, lists:reverse(Acc)}, Tail}.

cast_table_name(Bin, SQL) ->
    case re:run(SQL,<<"CHECK \\('(bin|lst|am)'='(bin|lst|am)'\\)\\)">>,[{capture,all_but_first,binary}]) of
    {match, [<<"bin">>, <<"bin">>]} ->
        Bin;
    {match, [<<"lst">>, <<"lst">>]} ->
        unicode:characters_to_list(Bin, latin1);
    {match, [<<"am">>, <<"am">>]} ->
        binary_to_atom(Bin, latin1);
    _ ->
        %% backwards compatible
        binary_to_atom(Bin, latin1)
    end.

to_list(V) when is_list(V)   -> V;
to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) when is_atom(V)   -> atom_to_list(V);
to_list(V)                   -> io_lib:format("~p", [V]).

%% conflict_clause(["ON", "CONFLICT", ResolutionString | Tail]) ->
%%     Resolution = case ResolutionString of
%%                      "ROLLBACK" -> rollback;
%%                      "ABORT" -> abort;
%%                      "FAIL" -> fail;
%%                      "IGNORE" -> ignore;
%%                      "REPLACE" -> replace
%%                  end,
%%     {{on_conflict, Resolution}, Tail};
%% conflict_clause(NoOnConflictClause) ->
%%     {no_on_conflict, NoOnConflictClause}.

%%--------------------------------------------------------------------
%% @type db() = atom() | pid()
%% Functions which take databases accept either the name the database is registered under
%% or the PID.
%% @end
%% @type sql_value() = null | number() | iodata() | {blob, binary()}.
%%
%% Values accepted in SQL statements are atom 'null', numbers,
%% strings (represented as iodata()) and blobs.
%% @end
%% @type sql_type() = integer | text | double | blob | atom() | string().
%%
%% Types of SQLite columns are represented by atoms 'integer', 'text', 'double',
%% 'blob'. Other atoms and strings may also be used (e.g. "VARCHAR(20)", 'smallint', etc.)
%% See [http://www.sqlite.org/datatype3.html].
%% @end
%% @type pk_constraint() = autoincrement | desc | asc.
%% See {@link pk_constraints()}.
%% @type pk_constraints() = pk_constraint() | [pk_constraint()].
%% See {@link column_constraint()}.
%% @type column_constraint() = non_null | primary_key | {primary_key, pk_constraints()}
%%                             | unique | {default, sql_value()} | {raw, string()}.
%% See {@link column_constraints()}.
%% @type column_constraints() = column_constraint() | [column_constraint()].
%% See {@link table_info()}.
%% @type table_info() = [{atom(), sql_type()} | {atom(), sql_type(), column_constraints()}].
%%
%% Describes the columns of an SQLite table: each tuple contains name, type and constraints (if any)
%% of one column.
%% @end
%% @type table_constraint() = {primary_key, [atom()]} | {unique, [atom()]} | {raw, string()}.
%% @type table_constraints() = table_constraint() | [table_constraint()].
%%
%% Currently supported constraints for {@link table_info()} and {@link sqlite3:create_table/4}.
%% @end
%% @type sqlite_error() = {'error', integer(), string()} | {'error', any()}.
%%
%% Errors reported by SQLite side are represented by 3-element tuples containing
%% atom 'error', SQLite result code ([http://www.sqlite.org/c3ref/c_abort.html],
%% [http://www.sqlite.org/c3ref/c_busy_recovery.html]) and an English-language error
%% message.
%%
%% Errors occuring on the Erlang side are represented by 2-element tuples with
%% first element 'error'.
%% @end
%% @type sql_non_query_result() = ok | sqlite_error() | {rowid, integer()}.
%% The result returned by functions which call the database but don't return
%% any records.
%% @end
%% @type sql_result() = sql_non_query_result() | [{columns, [string()]} | {rows, [tuple()]} | sqlite_error()].
%% The result returned by functions which query the database. If there are errors,
%% list of three tuples is returned: [{columns, ListOfColumnNames}, {rows, ListOfResults}, ErrorTuple].
%% If there are no errors, the list has two elements.
%% @end
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
