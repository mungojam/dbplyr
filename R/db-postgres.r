#' @export
db_desc.PostgreSQLConnection <- function(x) {
  info <- dbGetInfo(x)
  host <- if (info$host == "") "localhost" else info$host

  paste0("postgres ", info$serverVersion, " [", info$user, "@",
    host, ":", info$port, "/", info$dbname, "]")
}

#' @export
sql_translate_env.PostgreSQLConnection <- function(con) {
  sql_variant(
    sql_translator(.parent = base_scalar,
      log = function(x, base = exp(1)) {
        if (isTRUE(all.equal(base, exp(1)))) {
          build_sql("ln(", x, ")")
        } else {
          # Use log change-of-base because postgres doesn't support the
          # two-argument "log(base, x)" for floating point x.
          build_sql("log(", x, ") / log(", base, ")")
        }
      },
      log10  = function(x) build_sql("log(", x, ")"),
      cot    = function(x) build_sql("1 / TAN(", x, ")"),
      cosh   = function(x) build_sql("(EXP(", x, ") + EXP(-", x,")) / 2"),
      sinh   = function(x) build_sql("(EXP(", x, ") - EXP(-", x,")) / 2"),
      tanh   = function(x) {
        build_sql(
          "((EXP(", x, ") - EXP(-", x,")) / 2) / ((EXP(", x, ") + EXP(-", x,")) / 2)"
        )},
      coth   = function(x){
        build_sql(
          "((EXP(", x, ") + EXP(-", x,")) / 2) / ((EXP(", x, ") - EXP(-", x,")) / 2)"
        )},
      round  = function(x, digits = 0L){
        build_sql(
          "ROUND((", x, ")::numeric, ", as.integer(digits),")"
        )},
      paste  = function(..., sep = " "){
        build_sql(
          "CONCAT_WS(",sep, ", ",escape(c(...), parens = "", collapse = ","),")"
        )}
    ),
    sql_translator(.parent = base_agg,
      n = function() sql("COUNT(*)"),
      cor = sql_prefix("corr"),
      cov = sql_prefix("covar_samp"),
      sd = sql_aggregate("stddev_samp"),
      var = sql_aggregate("var_samp"),
      all = sql_aggregate("bool_and"),
      any = sql_aggregate("bool_or"),
      paste = function(x, collapse) build_sql("string_agg(", x, ", ", collapse, ")")
    ),
    sql_translator(.parent = base_win,
      n = function() {
        win_over(sql("COUNT(*)"), partition = win_current_group())
      },
      cor = win_aggregate("corr"),
      cov = win_aggregate("covar_samp"),
      sd =  win_aggregate("stddev_samp"),
      var = win_aggregate("var_samp"),
      all = win_aggregate("bool_and"),
      any = win_aggregate("bool_or"),
      paste = function(x, collapse) {
        win_over(
          build_sql("string_agg(", x, ", ", collapse, ")"),
          partition = win_current_group(),
          order = win_current_order()
        )
      }
    )
  )
}

# DBI methods ------------------------------------------------------------------

# Doesn't return TRUE for temporary tables
#' @export
db_has_table.PostgreSQLConnection <- function(con, table, ...) {
  table %in% db_list_tables(con)
}

#' @export
db_begin.PostgreSQLConnection <- function(con, ...) {
  dbExecute(con, "BEGIN TRANSACTION")
}

# http://www.postgresql.org/docs/9.3/static/sql-explain.html
#' @export
db_explain.PostgreSQLConnection <- function(con, sql, format = "text", ...) {
  format <- match.arg(format, c("text", "json", "yaml", "xml"))

  exsql <- build_sql(
    "EXPLAIN ",
    if (!is.null(format)) build_sql("(FORMAT ", sql(format), ") "),
    sql
  )
  expl <- dbGetQuery(con, exsql)

  paste(expl[[1]], collapse = "\n")
}

#' @export
db_write_table.PostgreSQLConnection <- function(con, table, types, values,
                                                temporary = TRUE, ...) {

  db_create_table(con, table, types, temporary = temporary)

  if (nrow(values) == 0)
    return(NULL)

  cols <- lapply(values, escape, collapse = NULL, parens = FALSE, con = con)
  col_mat <- matrix(unlist(cols, use.names = FALSE), nrow = nrow(values))

  rows <- apply(col_mat, 1, paste0, collapse = ", ")
  values <- paste0("(", rows, ")", collapse = "\n, ")

  sql <- build_sql("INSERT INTO ", ident(table), " VALUES ", sql(values))
  dbExecute(con, sql)
}

#' @export
db_query_fields.PostgreSQLConnection <- function(con, sql, ...) {
  fields <- build_sql(
    "SELECT * FROM ", sql_subquery(con, sql), " WHERE 0=1",
    con = con
  )

  qry <- dbSendQuery(con, fields)
  on.exit(dbClearResult(qry))

  dbGetInfo(qry)$fieldDescription[[1]]$name
}
