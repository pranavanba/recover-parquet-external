
# Functions ---------------------------------------------------------------

#' Get Identifier Variable Values for Withdrawn Participants
#'
#' This function gets the values of an identifier variable in 
#' datasets that do not contain the ParticipantIdentifier variable, but 
#' only for the corresponding ParticipantIdentifer values that are found 
#' in a list containing ParticipantIdentifier values of withdrawn participants. 
#' For example, if dataset A contains ParticipantIdentifier and DataKey columns, 
#' and dataset B contains the DataKey column but not the ParticipantIdentifier 
#' column, then we can map datasetB.DataKey to datasetA.ParticipantIdentifier 
#' using datasetA.DataKey and datasetB.DataKey, filtering by values of 
#' datasetA.ParticipantIdentifier that meet some criteria.
#'
#' @param dataset_name The name of a dataset that has the ParticipantIdentifier 
#' variable and the mapping identifier variable (`mappingID_var`).
#' @param mappingID_var The name of an identifier variable that can be 
#' mapped to ParticipantIdentifier in the `dataset_name`'s parent dataset.
#'
#' @return The values of `mappingID_var` after filtering the dataset.
#'
#' @examples
#' values_to_withdraw <- 
#' get_mappingID_vals_to_withdraw("my_dataset", "DataPointKey")
#' 
get_mappingID_vals_to_withdraw <- function(dataset_name, mappingID_var) {
  arrow::open_dataset(paste0(AWS_PARQUET_DOWNLOAD_LOCATION, "/", dataset_name, "/")) %>% 
    dplyr::select(dplyr::all_of(c("ParticipantIdentifier", mappingID_var))) %>% 
    dplyr::filter(ParticipantIdentifier %in% participants_to_withdraw) %>% 
    dplyr::collect() %>% 
    dplyr::pull(mappingID_var) %>% 
    unique()
}

# Main --------------------------------------------------------------------

# Get list of ParticipantIdentifiers of withdrawn participants
participants_to_withdraw <- 
  arrow::open_dataset(paste0(AWS_PARQUET_DOWNLOAD_LOCATION, "/dataset_enrolledparticipants/")) %>% 
  dplyr::select(ParticipantIdentifier, CustomFields_EOPRemoveData) %>% 
  dplyr::filter(as.character(CustomFields_EOPRemoveData)=="1") %>%
  dplyr::collect() %>% 
  dplyr::pull(ParticipantIdentifier) %>% 
  unique()

if (length(participants_to_withdraw) > 0) {
  # Store list of datasets that do not contain ParticipantIdentifier column
  contains_pid_false <- 
    sapply(list.dirs(AWS_PARQUET_DOWNLOAD_LOCATION, recursive = F), function(x) {
      grepl("ParticipantIdentifier", open_dataset(x)$metadata$org.apache.spark.sql.parquet.row.metadata)
    }) %>% 
    tibble::enframe() %>% 
    dplyr::filter(value==FALSE) %>% 
    dplyr::select(name)
  
  # Store mapping ID var name for corresponding datasets
  contains_pid_false$mappingID <- 
    dplyr::case_when(
      grepl("fitbitsleeplogs", contains_pid_false$name) == TRUE ~ "LogId",
      grepl("healthkitv2electrocardiogram", contains_pid_false$name) == TRUE ~ "HealthKitECGSampleKey",
      grepl("healthkitv2heartbeat", contains_pid_false$name) == TRUE ~ "HealthKitHeartbeatSampleKey",
      grepl("healthkitv2workout", contains_pid_false$name) == TRUE ~ "HealthKitWorkoutKey",
      grepl("symptomlog_value", contains_pid_false$name) == TRUE ~ "DataPointKey"
    )
  
  # Get values of mapping ID vars for participants to withdraw
  contains_pid_false$participants_to_withdraw <- 
    dplyr::case_when(
      grepl("fitbitsleeplogs", contains_pid_false$name) == TRUE ~ list(get_mappingID_vals_to_withdraw("dataset_fitbitsleeplogs", "LogId")),
      grepl("healthkitv2electrocardiogram", contains_pid_false$name) == TRUE ~ list(get_mappingID_vals_to_withdraw("dataset_healthkitv2electrocardiogram", "HealthKitECGSampleKey")),
      grepl("healthkitv2heartbeat", contains_pid_false$name) == TRUE ~ list(get_mappingID_vals_to_withdraw("dataset_healthkitv2heartbeat", "HealthKitHeartbeatSampleKey")),
      grepl("healthkitv2workout", contains_pid_false$name) == TRUE ~ list(get_mappingID_vals_to_withdraw("dataset_healthkitv2workouts", "HealthKitWorkoutKey")),
      grepl("symptomlog_value", contains_pid_false$name) == TRUE ~ list(get_mappingID_vals_to_withdraw("dataset_symptomlog", "DataPointKey"))
    )
  
  # Remove data for withdrawn participants from parquet datasets based on mapping ID variables
  lapply(list.dirs(AWS_PARQUET_DOWNLOAD_LOCATION, recursive = F), function(x) {
    if (x %in% contains_pid_false$name) {
      tmpret <- unlist(contains_pid_false$participants_to_withdraw[x == contains_pid_false$name])
      d <- 
        arrow::open_dataset(x) %>%
        filter(!(!!(as.symbol(contains_pid_false$mappingID[x == contains_pid_false$name]))) %in% tmpret)
    } else {
      d <-
        arrow::open_dataset(x) %>%
        filter(!ParticipantIdentifier %in% participants_to_withdraw)
    }
    d %>% 
      arrow::write_dataset(
        path = file.path(POST_WITHDRAW_LOCATION, basename(x)),
        max_open_files = 2048,
        max_rows_per_file = 5000000,
        partitioning = "cohort",
        existing_data_behavior = 'delete_matching',
        basename_template = paste0("part-0000{i}.", as.character("parquet"))
      )
  })
  
  unlink(AWS_PARQUET_DOWNLOAD_LOCATION, recursive = T, force = T)
  system(glue::glue("cp -r {POST_WITHDRAW_LOCATION} {AWS_PARQUET_DOWNLOAD_LOCATION}"))
  unlink(POST_WITHDRAW_LOCATION, recursive = T, force = T)
}

