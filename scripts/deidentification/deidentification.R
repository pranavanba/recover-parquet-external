library(synapser)
library(synapserutils)
library(tidyr)
library(dplyr)

synLogin()

unlink('./dictionaries/', recursive = T, force = T)

# Get dictionaries --------------------------------------------------------
system('synapse get -r syn52316269 --downloadLocation ./dictionaries/ --manifest suppress')

list.files("./dictionaries", full.names = T) %>% 
  lapply(function(x) {
    y <- x %>% stringr::str_remove_all("[0-9]|_[0-9]+")
    file.rename(from = x, to = y)
  })

junk <- lapply(list.files("./dictionaries/", full.names = T), function(f) {
  lines <- readLines(f)
  
  # Ensure there is a proper newline at the end
  if (substr(lines[length(lines)], nchar(lines[length(lines)]), nchar(lines[length(lines)])) != "\n") {
    lines[length(lines)] <- paste0(lines[length(lines)] , "\n")
  }
  
  # Process and clean the lines
  modified_lines <- lapply(lines, function(line) {
    line <- iconv(line, from = "UTF-8", to = "ASCII//TRANSLIT", sub = "")
    line <- gsub('"', '', line)
    if (grepl(",APPROVED|,UNAPPROVED", line)) {
      line <- gsub('(.*?)"?(,APPROVED|,approved|,UNAPPROVED|,unapproved)', '"\\1"\\2', line)
    }
    return(line)
  })
  
  modified_lines <- unlist(modified_lines)
  
  writeLines(modified_lines, f)
})


store_dicts <- function(files_dir) {
  dicts <- list()

  for (f in list.files(files_dir)) {
    file_path <- file.path(files_dir, file.path(f))
    filename <- tools::file_path_sans_ext(basename(file_path))
    new_dict_name <- sub("^Dictionary_", "", filename)
    data <- read.csv(file_path)
    dicts[[new_dict_name]] <- data
  }
  return(dicts)
}

dicts <- store_dicts('./dictionaries')

for (i in seq_along(dicts)) {
  dicts[[i]][[1]] <- trimws(dicts[[i]][[1]])
}


# De-identify datasets that have dictionaries -----------------------------
deidentify <- function(dicts_list, parquet_dir) {
  out_list <- list()
  review_list <- list()
  
  for (i in seq_along(dicts_list)) {
    var_name <- colnames(dicts_list[[i]])[1]
    status_col <- colnames(dicts_list[[i]])[2]
    
    df <- open_dataset(paste0(parquet_dir, '/', names(dicts_list)[i])) %>% collect()
    df[[var_name]] <- tolower(df[[var_name]])
    
    out <- df
    out[[var_name]] <- trimws(out[[var_name]])
    
    needs_review <- character(0)
    
    for (j in 1:nrow(out)) {
      val <- out[[var_name]][j]
      
      # Find the status for the value
      status_idx <- which(dicts_list[[i]][[1]] == val)
      
      if (length(status_idx) > 0) {
        status <- dicts_list[[i]][[2]][status_idx]
        
        # Check the status and apply de-identification
        if (status == "UNAPPROVED") {
          out[[var_name]][j] <- NA
        }
      } else {
        # No match in dictionary, mark for review and set value to NA
        needs_review <- c(needs_review, val)
        out[[var_name]][j] <- NA
      }
    }
    
    needs_review <- unique(needs_review)
    
    out_list[[i]] <- out
    review_list[[i]] <- needs_review
  }
  
  names(out_list) <- names(dicts_list)
  names(review_list) <- names(dicts_list)
  
  results <- list(out_list, review_list)
  names(results) <- c('deidentified_datasets', 'values_to_review')
  
  return(results)
}

deidentified_results <- deidentify(dicts, PARQUET_FINAL_LOCATION)

# Write de-identified datasets to parquet datasets dir --------------------
for (i in seq_along(deidentified_results$deidentified_datasets)) {
  dir <- file.path(PARQUET_FINAL_LOCATION, names(deidentified_results$deidentified_datasets)[[i]])
  unlink(dir, recursive = T, force = T)
  dir.create(dir)
  
  arrow::write_dataset(dataset = deidentified_results$deidentified_datasets[[i]], 
                       path = file.path(PARQUET_FINAL_LOCATION, names(deidentified_results$deidentified_datasets)[[i]]), 
                       max_open_files = 2048,
                       max_rows_per_file = 5000000,
                       partitioning = c('cohort'), 
                       existing_data_behavior = 'delete_matching',
                       basename_template = paste0("part-0000{i}.", as.character("parquet")))
}


# Store vectors containing values to review in Synapse --------------------
dir.create('./dictionaries/new_to_review')
for (i in seq_along(deidentified_results$values_to_review)) {
  if (length(deidentified_results$values_to_review[[i]]) > 0) {
    f <- write.csv(deidentified_results$values_to_review[[i]], 
                   file = paste0('./dictionaries/new_to_review/values_to_review_',names(deidentified_results$values_to_review)[[i]], '.csv'), 
                   row.names = F)
  }
}

# Index each file in Synapse
latest_commit <- gh::gh("/repos/:owner/:repo/commits/main", owner = "Sage-Bionetworks", repo = "recover-parquet-external")
latest_commit_file_url <- paste0(latest_commit$html_url %>% stringr::str_replace("commit", "blob"), "/scripts/deidentification/deidentification.R")

for (i in seq_along(list.files('./dictionaries/new_to_review/'))) {
  synStore(File(path = list.files('./dictionaries/new_to_review', full.names = T)[i],
                parent = DEID_VALS_TO_REVIEW),
          activityName = "Indexing",
          activityDescription = "Indexing files containing new PII values to review for deidentification step",
          used = c((synGetChildren(DICTIONARIES_FOLDER) %>% as.list())[[i]]$id,
                   synFindEntityId(names(deidentified_results$deidentified_datasets)[i],
                                   parent = PARQUET_FOLDER_INTERNAL)),
          executed = latest_commit_file_url
          )
}
