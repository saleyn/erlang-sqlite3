#include "sqlite3_drv.h"

// Callback Array
static ErlDrvEntry basic_driver_entry = {
    NULL,                             /* init */
    start,                            /* startup (defined below) */
    stop,                             /* shutdown (defined below) */
    NULL,                             /* output */
    NULL,                             /* ready_input */
    NULL,                             /* ready_output */
    "sqlite3_drv",                    /* the name of the driver */
    NULL,                             /* finish */
    NULL,                             /* handle */
    control,                          /* control */
    NULL,                             /* timeout */
    NULL,                             /* outputv (defined below) */
    ready_async,                      /* ready_async */
    NULL,                             /* flush */
    NULL,                             /* call */
    NULL,                             /* event */
    ERL_DRV_EXTENDED_MARKER,          /* ERL_DRV_EXTENDED_MARKER */
    ERL_DRV_EXTENDED_MAJOR_VERSION,   /* ERL_DRV_EXTENDED_MAJOR_VERSION */
    ERL_DRV_EXTENDED_MAJOR_VERSION,   /* ERL_DRV_EXTENDED_MINOR_VERSION */
    ERL_DRV_FLAG_USE_PORT_LOCKING     /* ERL_DRV_FLAGs */
};

DRIVER_INIT(basic_driver) {
  return &basic_driver_entry;
}

// Driver Start
static ErlDrvData start(ErlDrvPort port, char* cmd) {
  sqlite3_drv_t* retval = (sqlite3_drv_t*) driver_alloc(sizeof(sqlite3_drv_t));
  struct sqlite3 *db;
  int status;
  
  // Create and open the database
  sqlite3_open(DB_PATH, &db);
  status = sqlite3_errcode(db);

  if(status != SQLITE_OK) {
    fprintf(stderr, "Unabled to open file: %s because %s\n\n", DB_PATH, sqlite3_errmsg(db));
  }
  fprintf(stderr, "Opened file %s\n", DB_PATH);

  // Set the state for the driver
  retval->port = port;
  retval->db = db;
  retval->key = 42; //FIXME: Just a magic number, make real key
  
  return (ErlDrvData) retval;
}


// Driver Stop
static void stop(ErlDrvData handle) {
  sqlite3_drv_t* driver_data = (sqlite3_drv_t*) handle;

  sqlite3_close(driver_data->db);
  driver_free(driver_data);
}

// Handle input from Erlang VM
static int control(ErlDrvData drv_data, unsigned int command, char *buf, 
                   int len, char **rbuf, int rlen) {
  sqlite3_drv_t* driver_data = (sqlite3_drv_t*) drv_data;
  
  switch(command) {
    case CMD_SQL_EXEC:
      sql_exec(driver_data, buf, len);
      break;
    default:
      unknown(driver_data, buf, len);
  }
  return 0;
}


static inline int return_error(sqlite3_drv_t *drv, const char *error, ErlDrvTermData **spec, int *terms_count) {
  *spec = (ErlDrvTermData *)calloc(7, sizeof(ErlDrvTermData));
  (*spec)[0] = ERL_DRV_ATOM;
  (*spec)[1] = driver_mk_atom("error");
  (*spec)[2] = ERL_DRV_STRING;
  (*spec)[3] = (ErlDrvTermData)error;
  (*spec)[4] = strlen(error);
  (*spec)[5] = ERL_DRV_TUPLE;
  (*spec)[6] = 2;
  *terms_count = 7;
  return 0;
}

static int sql_exec(sqlite3_drv_t *drv, char *command, int command_size) {

  int result, next_row;
  char *rest = NULL;
  sqlite3_stmt *statement;
  
  result = sqlite3_prepare_v2(drv->db, command, command_size, &statement, (const char **)&rest);
  if(result != SQLITE_OK) { 
    ErlDrvTermData *dataset;
    int term_count;
    return_error(drv, sqlite3_errmsg(drv->db), &dataset, &term_count); 
    driver_output_term(drv->port, dataset, term_count);
    return 0;
  }
  
  async_sqlite3_command *async_command = (async_sqlite3_command *)calloc(1, sizeof(async_sqlite3_command));
  async_command->driver_data = drv;
  async_command->statement = statement;

  // fprintf(stderr, "Driver async: %d %p\n", SQLITE_VERSION_NUMBER, async_command->statement);

  if (1) {
    sql_exec_async(async_command);
    ready_async((ErlDrvData)drv, (ErlDrvThreadData)async_command);
  } else {
    drv->async_handle = driver_async(drv->port, &drv->key, sql_exec_async, async_command, sql_free_async);
  }
  return 0;
}

static void sql_free_async(void *_async_command)
{
  int i;
  async_sqlite3_command *async_command = (async_sqlite3_command *)_async_command;
  free(async_command->dataset);
  
  async_command->driver_data->async_handle = 0;
  
  if (async_command->floats) {
    free(async_command->floats);
  }
  for (i = 0; i < async_command->binaries_count; i++) {
    driver_free_binary(async_command->binaries[i]);
  }
  if(async_command->binaries) {
    free(async_command->binaries);
  }
  if (async_command->statement) {
    sqlite3_finalize(async_command->statement);
  }
  free(async_command);
}

  
static void sql_exec_async(void *_async_command) {
  async_sqlite3_command *async_command = (async_sqlite3_command *)_async_command;
  ErlDrvTermData *dataset = async_command->dataset;
  int term_count = async_command->term_count;
  int row_count = async_command->row_count;
  sqlite3_drv_t *drv = async_command->driver_data;

  int result, next_row, column_count;
  char *error = NULL;
  char *rest = NULL;
  sqlite3_stmt *statement = async_command->statement;
  
  double *floats = NULL;
  int float_count = 0;
  
  ErlDrvBinary **binaries = NULL;
  int binaries_count = 0;
  int i;
  
  
  column_count = sqlite3_column_count(statement);
  dataset = NULL;

  term_count += 2;
  dataset = realloc(dataset, sizeof(*dataset) * term_count);
  dataset[term_count - 2] = ERL_DRV_PORT;
  dataset[term_count - 1] = driver_mk_port(drv->port);
  
  if (column_count > 0) {
    int base = term_count;
    term_count += 2 + column_count*2 + 1 + 2 + 2 + 2;
    dataset = realloc(dataset, sizeof(*dataset) * term_count);
    dataset[base] = ERL_DRV_ATOM;
    dataset[base + 1] = driver_mk_atom("columns");
    for (i = 0; i < column_count; i++) {
      dataset[base + 2 + (i*2)] = ERL_DRV_ATOM;
      // fprintf(stderr, "Column: %s\n", sqlite3_column_name(statement, i));
      dataset[base + 2 + (i*2) + 1] = driver_mk_atom((char *)sqlite3_column_name(statement, i));
    }
    dataset[base + 2 + column_count*2 + 0] = ERL_DRV_NIL;
    dataset[base + 2 + column_count*2 + 1] = ERL_DRV_LIST;
    dataset[base + 2 + column_count*2 + 2] = column_count + 1;
    dataset[base + 2 + column_count*2 + 3] = ERL_DRV_TUPLE;
    dataset[base + 2 + column_count*2 + 4] = 2;

    dataset[base + 2 + column_count*2 + 5] = ERL_DRV_ATOM;
    dataset[base + 2 + column_count*2 + 6] = driver_mk_atom("rows");
  }

  fprintf(stderr, "Exec: %s\n", sqlite3_sql(statement));
  
  while ((next_row = sqlite3_step(statement)) == SQLITE_ROW) {

    for (i = 0; i < column_count; i++) {
      // fprintf(stderr, "Column %d type: %d\n", i, sqlite3_column_type(statement, i));
      switch (sqlite3_column_type(statement, i)) {
        case SQLITE_INTEGER: {
          term_count += 2;
          dataset = realloc(dataset, sizeof(*dataset) * term_count);
          dataset[term_count - 2] = ERL_DRV_INT;
          dataset[term_count - 1] = sqlite3_column_int(statement, i);
          break;
        }
        case SQLITE_FLOAT: {
          float_count++;
          floats = realloc(floats, sizeof(double) * float_count);
          floats[float_count - 1] = sqlite3_column_double(statement, i);

          term_count += 2;
          dataset = realloc(dataset, sizeof(*dataset) * term_count);
          dataset[term_count - 2] = ERL_DRV_FLOAT;
          dataset[term_count - 1] = (ErlDrvTermData)&floats[float_count - 1];
          break;
        }
        case SQLITE_BLOB: 
        case SQLITE_TEXT: {
          int bytes = sqlite3_column_bytes(statement, i);
          binaries_count++;
          binaries = realloc(binaries, sizeof(*binaries) * binaries_count);
          binaries[binaries_count - 1] = driver_alloc_binary(bytes);
          binaries[binaries_count - 1]->orig_size = bytes;
          memcpy(binaries[binaries_count - 1]->orig_bytes, sqlite3_column_blob(statement, i), bytes);

          term_count += 4;
          dataset = realloc(dataset, sizeof(*dataset) * term_count);
          dataset[term_count - 4] = ERL_DRV_BINARY;
          dataset[term_count - 3] = (ErlDrvTermData)binaries[binaries_count - 1];
          dataset[term_count - 2] = bytes;
          dataset[term_count - 1] = 0;
          break;
        }
        case SQLITE_NULL: {
          break;
        }
      }
    }
    term_count += 2;
    dataset = realloc(dataset, sizeof(*dataset) * term_count);
    dataset[term_count - 2] = ERL_DRV_TUPLE;
    dataset[term_count - 1] = column_count;

    row_count++;
  }
  async_command->row_count = row_count;
  async_command->floats = floats;
  async_command->binaries = binaries;
  async_command->binaries_count = binaries_count;
  
  
  if (next_row == SQLITE_BUSY) {
    return_error(drv, "SQLite3 database is busy", &async_command->dataset, &async_command->term_count);
    return;
  }
  if (next_row != SQLITE_DONE) {
    return_error(drv, sqlite3_errmsg(drv->db), &async_command->dataset, &async_command->term_count);
    return;
  }
  

  if (column_count > 0) {
    term_count += 3;
    dataset = realloc(dataset, sizeof(*dataset) * term_count);
    dataset[term_count - 3] = ERL_DRV_NIL;
    dataset[term_count - 2] = ERL_DRV_LIST;
    dataset[term_count - 1] = row_count + 1;

    term_count += 2;
    dataset = realloc(dataset, sizeof(*dataset) * term_count);
    dataset[term_count - 2] = ERL_DRV_TUPLE;
    dataset[term_count - 1] = 2;


    term_count += 3;
    dataset = realloc(dataset, sizeof(*dataset) * term_count);
    dataset[term_count - 3] = ERL_DRV_NIL;
    dataset[term_count - 2] = ERL_DRV_LIST;
    dataset[term_count - 1] = 3;

  } else if (strcasestr(sqlite3_sql(statement), "INSERT"))  {
    
    long long rowid = sqlite3_last_insert_rowid(drv->db);
    term_count += 6;
    dataset = realloc(dataset, sizeof(*dataset) * term_count);
    dataset[term_count - 6] = ERL_DRV_ATOM;
    dataset[term_count - 5] = driver_mk_atom("id");
    dataset[term_count - 4] = ERL_DRV_INT;
    dataset[term_count - 3] = rowid;
    dataset[term_count - 2] = ERL_DRV_TUPLE;
    dataset[term_count - 1] = 2;
  } else {
    term_count += 6;
    dataset = realloc(dataset, sizeof(*dataset) * term_count);
    dataset[term_count - 6] = ERL_DRV_ATOM;
    dataset[term_count - 5] = driver_mk_atom("ok");
    dataset[term_count - 4] = ERL_DRV_INT;
    dataset[term_count - 3] = next_row;
    dataset[term_count - 2] = ERL_DRV_TUPLE;
    dataset[term_count - 1] = 2;
  }
  
  term_count += 2;
  dataset = realloc(dataset, sizeof(*dataset) * term_count);
  dataset[term_count - 2] = ERL_DRV_TUPLE;
  dataset[term_count - 1] = 2;
  

  
  
  async_command->dataset = dataset;
  async_command->term_count = term_count;
  fprintf(stderr, "Total term count: %p %d, rows count: %dx%d\n", statement, term_count, column_count, row_count);
}

static void ready_async(ErlDrvData drv_data, ErlDrvThreadData thread_data)
{
  async_sqlite3_command *async_command = (async_sqlite3_command *)thread_data;
  sqlite3_drv_t *drv = async_command->driver_data;
  
  int res = driver_output_term(drv->port, async_command->dataset, async_command->term_count);
  fprintf(stderr, "Total term count: %p %d, rows count: %d (%d)\n", async_command->statement, async_command->term_count, async_command->row_count, res);
  sql_free_async(async_command);
}


// Unkown Command
static int unknown(sqlite3_drv_t *drv, char *command, int command_size) {
  // Return {error, unkown_command}
  ErlDrvTermData spec[] = {ERL_DRV_ATOM, driver_mk_atom("error"),
			   ERL_DRV_ATOM, driver_mk_atom("uknown_command"),
			   ERL_DRV_TUPLE, 2};
  return driver_output_term(drv->port, spec, sizeof(spec) / sizeof(spec[0]));
}