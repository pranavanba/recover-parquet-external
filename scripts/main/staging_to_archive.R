library(synapser)
library(tidyverse)

#' Replace equal sign with underscore
#'
#' This function renames a directory path by replacing equal signs with underscores.
#' If a replacement is performed, it logs the change.
#'
#' @param directory_path The path of the directory to rename.
#'
#' @examples
#' replace_equal_with_underscore("path_with=equals")
#' 
replace_equal_with_underscore <- function(directory_path) {
  new_directory_path <- gsub("=", "_", directory_path)
  if (directory_path != new_directory_path) {
    file.rename(directory_path, new_directory_path)
    return(cat("Renamed:", directory_path, "to", new_directory_path, "\n"))
  }
}

unlink(x = c(config::get("AWS_ARCHIVE_DOWNLOAD_LOCATION", "staging"),
             config::get("PARQUET_FINAL_LOCATION", "staging")), 
       recursive = TRUE, 
       force = TRUE)

synapser::synLogin(authToken = Sys.getenv('SYNAPSE_AUTH_TOKEN'))

base_s3_uri_staging <- 
  paste0('s3://', 
         config::get("PARQUET_BUCKET_EXTERNAL", "staging"), 
         '/', 
         config::get("PARQUET_BUCKET_BASE_KEY_ARCHIVE", "staging"))

rm(list = names(config::get(config = "staging")))
config::get(config = "prod") %>% list2env(envir = .GlobalEnv)

base_s3_uri_archive <- 
  paste0('s3://', 
         PARQUET_BUCKET_EXTERNAL, 
         '/', 
         PARQUET_BUCKET_BASE_KEY_ARCHIVE)

validated_date <- readline("Enter name of validated staging folder in yyyy-mm-dd format: ")

# Index files in Synapse --------------------------------------------------
if (!is.null(synFindEntityId(validated_date, config::get("PARQUET_FOLDER_ARCHIVE", "staging")))) {
  sync_cmd <- glue::glue("aws s3 --profile service-catalog sync {base_s3_uri_staging}{validated_date}/ {STAGING_TO_ARCHIVE_DOWNLOAD_LOCATION} --exclude '*owner.txt*' --exclude '*archive*'")
  system(sync_cmd)
  rm(sync_cmd)
  sync_cmd <- glue::glue("aws s3 --profile service-catalog sync {STAGING_TO_ARCHIVE_DOWNLOAD_LOCATION} {base_s3_uri_archive}{validated_date}/ --exclude '*owner.txt*' --exclude '*archive*'")
  system(sync_cmd)
  
  rm(sync_cmd)
  
  # Sync new date dir in archive bucket to local
  unlink(STAGING_TO_ARCHIVE_DOWNLOAD_LOCATION, recursive = T, force = T)
  unlink(AWS_ARCHIVE_DOWNLOAD_LOCATION, recursive = T, force = T)
  sync_cmd <- glue::glue('aws s3 --profile service-catalog sync {base_s3_uri_archive}{validated_date}/ {AWS_ARCHIVE_DOWNLOAD_LOCATION}/{validated_date}/ --exclude "*owner.txt*" --exclude "*archive*"')
  system(sync_cmd)
  
  # Modify cohort identifier in dir name
  junk <- sapply(list.dirs(AWS_ARCHIVE_DOWNLOAD_LOCATION), replace_equal_with_underscore)
  
  # Generate manifest of existing files
  SYNAPSE_AUTH_TOKEN <- Sys.getenv('SYNAPSE_AUTH_TOKEN')
  manifest_cmd <- glue::glue('SYNAPSE_AUTH_TOKEN="{SYNAPSE_AUTH_TOKEN}" synapse manifest --parent-id {PARQUET_FOLDER_ARCHIVE} --manifest ./current_manifest.tsv {AWS_ARCHIVE_DOWNLOAD_LOCATION}')
  system(manifest_cmd)
  
  # Get a list of all files to upload and their synapse locations (parentId)
  STR_LEN_PARQUET_FINAL_LOCATION <- stringr::str_length(AWS_ARCHIVE_DOWNLOAD_LOCATION)
  
  ## List all local files present (from manifest)
  synapse_manifest <- 
    read.csv('./current_manifest.tsv', sep = '\t', stringsAsFactors = F) %>%
    dplyr::filter(!grepl('owner.txt', path)) %>%
    dplyr::rowwise() %>%
    dplyr::mutate(file_key = stringr::str_sub(string = path, start = STR_LEN_PARQUET_FINAL_LOCATION+2)) %>%
    dplyr::mutate(s3_file_key = paste0(PARQUET_BUCKET_BASE_KEY_ARCHIVE, file_key)) %>%
    dplyr::mutate(md5_hash = as.character(tools::md5sum(path))) %>%
    dplyr::ungroup() %>% 
    dplyr::mutate(file_key = gsub("cohort_", "cohort=", file_key),
                  s3_file_key = gsub("cohort_", "cohort=", s3_file_key))
  
  
  # List all files currently indexed in Synapse
  synapse_fileview <- 
    synapser::synTableQuery(paste0('SELECT * FROM ', SYNAPSE_FILEVIEW_ID))$filepath %>%
    read.csv()
  synapse_fileview <- 
    synapser::synTableQuery(paste0('SELECT * FROM ', SYNAPSE_FILEVIEW_ID))$filepath %>% 
    read.csv()
  
  # Find the files in the manifest that are not yet indexed in Synapse
  if (nrow(synapse_fileview)>0) {
    synapse_manifest_to_upload <-
      synapse_manifest %>%
      dplyr::anti_join(
        synapse_fileview %>%
          dplyr::select(parent = parentId,
                        s3_file_key = dataFileKey,
                        md5_hash = dataFileMD5Hex))
  } else {
    synapse_manifest_to_upload <- synapse_manifest
  }
  
  # Index each file in Synapse
  latest_commit <- 
    gh::gh("/repos/:owner/:repo/commits/main", 
           owner = "Sage-Bionetworks", 
           repo = "recover-parquet-external")
  
  latest_commit_this_file <- 
    paste0(latest_commit$html_url %>% stringr::str_replace("commit", "blob"), 
           "/scripts/main/staging_to_archive.R")
  
  staging_file_provenance_used <- 
    synFindEntityId(validated_date, 
                    config::get("PARQUET_FOLDER_ARCHIVE", "staging")) %>% 
    synGetChildren() %>% 
    synapser::as.list() %>% 
    .[[1]] %>% 
    .$id %>% 
    synGetChildren() %>% 
    synapser::as.list() %>% 
    .[[1]] %>% 
    .$id %>% 
    synGetChildren() %>% 
    synapser::as.list() %>% 
    .[[1]] %>% 
    .$id %>% 
    synGetProvenance() %>% 
    as.character() %>% 
    stringr::str_extract(pattern = "(?<=Used:\n).*")
  
  act <- synapser::Activity(name = "Indexing",
                            description = "Indexing external parquet datasets",
                            used = staging_file_provenance_used, 
                            executed = latest_commit_this_file)
  
  if(nrow(synapse_manifest_to_upload) > 0){
    for(file_number in seq_len(nrow(synapse_manifest_to_upload))){
      tmp <- synapse_manifest_to_upload[file_number, c("path", "parent", "s3_file_key")]
      
      absolute_file_path <- tools::file_path_as_absolute(tmp$path)
      
      temp_syn_obj <- 
        synapser::synCreateExternalS3FileHandle(
          bucket_name = PARQUET_BUCKET_EXTERNAL,
          s3_file_key = tmp$s3_file_key,
          file_path = absolute_file_path,
          parent = tmp$parent)
      
      new_fileName <- stringr::str_replace_all(temp_syn_obj$fileName, ':', '_colon_')
      
      f <- File(dataFileHandleId = temp_syn_obj$id,
                parentId = tmp$parent,
                name = new_fileName)
      
      f <- synStore(f, activity = act)
      
    }
  }
}
