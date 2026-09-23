# ---------------------------------------------------------------------------
# climate-indices | One-time package installation
#
#   source("install_dependencies.R")        # from the repository root
#   Rscript install_dependencies.R
# ---------------------------------------------------------------------------

required <- c("readxl", "writexl", "SPEI", "optparse")
optional <- c("ggplot2")   # only needed for --plot

install_missing <- function(pkgs, label) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) == 0L) {
    cat("All ", label, " packages already installed.\n", sep = "")
    return(invisible(character(0)))
  }
  cat("Installing ", label, ": ", paste(missing, collapse = ", "), "\n", sep = "")
  install.packages(missing, repos = "https://cloud.r-project.org")
  still <- missing[!vapply(missing, requireNamespace, logical(1), quietly = TRUE)]
  if (length(still) > 0L) {
    warning("Failed to install: ", paste(still, collapse = ", "), call. = FALSE)
  }
  invisible(still)
}

install_missing(required, "required")
install_missing(optional, "optional (figures)")

cat("\nR version: ", R.version.string, "\n", sep = "")
for (p in c(required, optional)) {
  if (requireNamespace(p, quietly = TRUE)) {
    cat(sprintf("  %-10s %s\n", p, as.character(utils::packageVersion(p))))
  }
}
