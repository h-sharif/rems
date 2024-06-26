# Copyright 2016 Province of British Columbia
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

#' Download and store the large historic ems dataset
#'
#' @param force Force downloading the dataset, even if it's not out of date
#'   (default \code{FALSE})
#' @param ask should the function ask for your permission to cache data on your
#'   computer? Default \code{TRUE}
#' @param dont_update should the function avoid updating the data even if there
#'   is a newer version available? Default \code{FALSE}
#' @param httr_config configuration settings passed on to [httr::GET()], such as
#'   [httr::timeout()]
#'
#' @return The path where the duckdb database is stored (invisibly).
#' @export
#'
#' @importFrom DBI dbConnect dbWriteTable dbDisconnect
#' @importFrom duckdb duckdb
#'
download_historic_data <- function(force = FALSE,
                                   ask = TRUE,
                                   dont_update = FALSE,
                                   httr_config = list(),
                                   session = NULL,
                                   id = NULL) {
  file_meta <- get_file_metadata("historic", "zip")
  cache_date <- get_cache_date("historic")
  db_path <- write_db_path()
  db_exists <- file.exists(db_path)

  if (db_exists & !force) {

    if (cache_date >= file_meta[["server_date"]]) {
      message("It appears that you already have the most up-to date version of the",
              " historic ems data.")
      return(invisible(db_path))
    }

    if (dont_update) {
      warning("There is a newer version of the historic ems data ",
              ", however you have asked not to update it by setting 'dont_update' to TRUE.")
      return(invisible(db_path))
    }
# nocov start
    if (ask) {
      ans <- readline(
        paste0(
          "Your version of the historic ems data is dated ",
          cache_date,
          " and there is a newer version available. Would you like to download it? (y/n)"
        )
      )
      if (tolower(ans) == "n") return(invisible(db_path))
    }
    # nocov end
  }

  # nocov start
  if (ask) {
    stop_for_permission(
      paste0(
        "rems would like to store a copy of the historic ems data at ",
        db_path,
        ". Is that okay?"
      )
    )
  }
  # nocov end

  message("This is going to take a while...")
  message("Downloading latest 'historic' EMS data")
  url <- paste0(base_url(), file_meta[["filename"]])
  csv_file <- download_ems_data(url, session = session, id = id)
  on.exit(unlink(csv_file), add = TRUE)

  if (db_exists) {
   file.remove(db_path)
   write_db_path()
  }
  create_rems_duckdb(csv_file, db_path, cache_date = file_meta[["server_date"]])
  message(
    "Successfully downloaded and stored the historic EMS data.\n",
    "You can access and subset it with the 'read_historic_data' function, or
      attach it as a remote data.frame with 'connect_historic_db()' and
      'attach_historic_data()' which you can then query with dplyr"
  )
  invisible(db_path)

}

#' Read historic ems data into R.
#'
#' You will need to have run \code{\link{download_historic_data}} before you
#' can use this function
#'
#' @param emsid A character vector of the ems id(s) of interest
#' @param parameter a character vector of parameter names
#' @param param_code a character vector of parameter codes
#' @param from_date A date string in a standard unambiguous format (e.g., "YYYY/MM/DD")
#' @param to_date A date string in a standard unambiguous format (e.g., "YYYY/MM/DD")
#' @param cols colums. Default "wq". See \code{link{get_ems_data}} for further documentation.
#' @param check_db should the function check for cached data or updates? Default \code{TRUE}.
#'
#' @return a data frame of the results
#' @export
#'
#' @importFrom DBI dbConnect dbDisconnect dbGetQuery
#' @examples
#' \dontrun{
#' read_historic_data(emsid = "0400203", from_date = as.Date("1984-11-20"),
#'   to_date = as.Date("1991-05-11"))
#' }
read_historic_data <- function(emsid = NULL, parameter = NULL, param_code = NULL,
                               from_date = NULL, to_date = NULL, cols = "wq", check_db = TRUE) {

  db_path <- write_db_path()
  exit_msg <- "Please download the historic data with\n the 'download_historic_data' function."

  if (!file.exists(db_path)) {
    stop(exit_msg, call. = FALSE)
  }

  ## Check for missing or outdated historic database
  if (check_db) {
    server_date <- get_file_metadata("historic", "zip")[["server_date"]]
    cache_date <- get_cache_date("historic")
    if (cache_date < server_date && file.exists(db_path)) {
      # nocov start
      ans <- readline(paste("Your version of the historic dataset is out of date.",
                            "Would you like to continue with the version you have (y/n)? ",
                            sep = "\n"))
      if (tolower(ans) != "y")
        stop(exit_msg, call. = FALSE)
      # nocov end
    }
  }

  qry <- construct_historic_sql(emsid = emsid, parameter = parameter,
                                param_code = param_code, from_date = from_date,
                                to_date = to_date, cols = cols)

  con <- duckdb_connect(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  res <- DBI::dbGetQuery(con, qry)

  ret <- tibble::as_tibble(res)

  add_rems_type(ret, "historic")

}

#' Create a database connection to the historic database
#'
#' This creates a DBI connection to the duckdb database
#' that holds the historic data table. You should call
#' [disconnect_historic_db()] when you are finished
#' querying the database.
#'
#' See [attach_historic_data()] for examples.
#'
#' @param db_path path to the duckdb database. In most cases
#'  it does not need to be specified as it uses the default location
#'  set by `rems`.
#'
#' @seealso [DBI::dbConnect()]
#' @return a DBIConnection object for communicating with the duckdb database
#' @export
connect_historic_db <- function(db_path = NULL) {
  if (is.null(db_path)) db_path <- write_db_path()
  if (!file.exists(db_path)) {
    stop("Please download the historic data with\n",
         " the 'download_historic_data' function.", call. = FALSE)
  }

  #snippet added temporarily to alert users of issue with duckdb removing timestamp, see issue #79
  #https://github.com/bcgov/rems/issues/79

  if (getRversion() >= numeric_version("4.3") &&
      packageVersion("duckdb") <= numeric_version("0.8.1.1")) {
    warning("This version of rems is using an outdated package version of duckdb which causes the time component of COLLECTION_START and COLLECTION_END to be omitted when query results are returned. To fix this issue, please ensure you update the duckdb package to version 0.8.1.3 or later. (See https://github.com/bcgov/rems/issues/79).")
  }
  # end of snippet

  message("Please remember to use 'disconnect_historic_db()' when you are finished querying the historic database.")
  duckdb_connect(db_path)
}

#' Close the connection to the historic database
#'
#' @param con DBI connection object, most likely created by [connect_historic_db()].
#'
#' @return `TRUE`, invisibly
#' @export
disconnect_historic_db <- function(con) {
  DBI::dbDisconnect(con, shutdown = TRUE)
}

#' Load the historic ems database as a tbl
#'
#' You can then use dplyr verbs such as \code{\link[dplyr]{filter}},
#' \code{\link[dplyr]{select}}, \code{\link[dplyr]{summarize}}, etc. For basic
#' importing of historic data based on \code{ems_id}, \code{date}, and \code{parameter},
#' you can use the function \code{\link{read_historic_data}}
#'
#' @param con DBI connection object, most likely created by [connect_historic_db()].
#'
#' @return A dplyr connection to the duckdb database. See \code{\link[dplyr]{tbl}} for more.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' library(dplyr)
#'
#' con <- connect_historic_db()
#'
#' hist_tbl <- attach_historic_data(con)
#' result <- hist_tbl %>%
#'  group_by(EMS_ID) %>%
#'  summarise(max_date = max(COLLECTION_START))
#' collect(result)
#'
#' disconnect_historic_db(con)
#' }
attach_historic_data <- function(con = NULL) {
  if (is.null(con)) {
    stop("You must specificy a database connection 'con', created by calling 'connect_historic_db()'.")
  }
  tbl <- dplyr::tbl(con, "historic")
  tbl
}

construct_historic_sql <- function(emsid = NULL, parameter = NULL, param_code = NULL,
                                   from_date = NULL, to_date = NULL, cols = NULL) {
  emsid_qry <- parameter_qry <- param_cd_qry <- from_date_qry <- to_date_qry <- col_query <- NULL
  if (!is.null(emsid)) {
    emsid <- pad_emsid(emsid)
    emsid_qry <- sprintf("EMS_ID IN (%s)", stringify_vec(emsid))
  }
  if (!is.null(parameter)) {
    parameter_qry <- sprintf("PARAMETER IN (%s)", stringify_vec(parameter))
  }
  if (!is.null(param_code)) {
    param_cd_qry <- sprintf("PARAMETER_CODE IN (%s)", stringify_vec(param_code))
  }

  if (!is.null(from_date)) {
    from_date <- format(as.Date(from_date), "%Y/%m/%d")
    from_date_qry <- sprintf("COLLECTION_START >= strptime('%s', '%%Y/%%m/%%d')", from_date)
  }
  if (!is.null(to_date)) {
    to_date <- format(as.Date(to_date), "%Y/%m/%d")
    to_date_qry <- sprintf("COLLECTION_START <= strptime('%s', '%%Y/%%m/%%d')", to_date)
  }
  where_clause_vec <- c(emsid_qry, parameter_qry, param_cd_qry, from_date_qry, to_date_qry)
  where_clause_vec <- where_clause_vec[!is.null(where_clause_vec)]
  where_clause <- paste(where_clause_vec, collapse = " AND ")

  if (is.null(cols) || cols == "all") {
    cols <- "*"
  } else if (cols == "wq") {
    cols <- wq_cols()
  }

  select_clause <- paste(cols, collapse = ", ")

  if (where_clause == "") {
    sql <- sprintf("SELECT %s FROM historic", select_clause)
  } else {
    sql <- sprintf("SELECT %s FROM historic WHERE %s", select_clause, where_clause)
  }

  sql
}

#' Turn a character vector into a string with items surrounded by quotes and
#' separated by commas
#'
#' @param vec
#'
#' @return character
#' @noRd
stringify_vec <- function(vec) {
  paste(shQuote(vec, "sh"), collapse = ",")
}

write_db_path <- function(path = getOption("rems.historic.path",
                                           default = rems_data_dir())) {
  fpath <- normalizePath(file.path(path, "duckdb/ems_historic.duckdb"),
                         mustWork = FALSE)
  dir.create(dirname(fpath), recursive = TRUE, showWarnings = FALSE)
  fpath
}

#' Add an index to a column in a DBI database
#'
#' @param con DBI connection
#' @param idxname desired name for the index
#' @param tblname table in the database
#' @param colname col on which to create an index
#'
#' @return NULL
#'
#' @noRd
add_sql_index <- function(con, tbl = "historic", colname,
                          idxname = paste0(tolower(colname), "_idx")) {
  sql_str <- sprintf("CREATE INDEX %s ON %s(%s)", idxname, tbl, colname)
  DBI::dbExecute(con, sql_str)
  invisible(NULL)
}

duckdb_connect <- function(db_path, read_only = TRUE) {
  DBI::dbConnect(duckdb::duckdb(), db_path, read_only = read_only,
                 timezone_out = "Etc/GMT+8", tz_out_convert = "force")
}
