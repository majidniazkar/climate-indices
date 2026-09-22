# ---------------------------------------------------------------------------
# climate-indices | Figures
# ---------------------------------------------------------------------------

#' Faceted time series of SPEI at every computed scale.
#'
#' Positive and negative anomalies are drawn as a filled area around zero,
#' with the +/-1 moderate-drought thresholds marked.
plot_spei_panels <- function(monthly, spei_names, path, width = 10, height = 2.0) {
  long <- do.call(rbind, lapply(spei_names, function(nm) {
    data.frame(Date  = monthly$Date,
               Scale = factor(nm, levels = spei_names,
                              labels = paste(sub("^SPEI_", "", spei_names), "month")),
               Value = monthly[[nm]],
               stringsAsFactors = FALSE)
  }))
  long <- long[!is.na(long$Value), , drop = FALSE]
  long$Sign <- ifelse(long$Value < 0, "Dry", "Wet")

  # One bar per month. An area fill would interpolate across zero crossings
  # and invent polygons that are not in the data.
  p <- ggplot2::ggplot(long, ggplot2::aes(x = Date, y = Value)) +
    ggplot2::geom_hline(yintercept = 0, colour = "grey40", linewidth = 0.3) +
    ggplot2::geom_hline(yintercept = c(-1, 1), colour = "grey70",
                        linetype = "dashed", linewidth = 0.3) +
    ggplot2::geom_col(ggplot2::aes(fill = Sign), width = 31) +
    ggplot2::scale_fill_manual(values = c(Dry = "#b2182b", Wet = "#2166ac"),
                               name = NULL) +
    ggplot2::facet_wrap(~Scale, ncol = 1, strip.position = "right") +
    ggplot2::labs(x = NULL, y = "SPEI (standard deviations)") +
    ggplot2::theme_bw(base_size = 10) +
    ggplot2::theme(legend.position = "top",
                   panel.grid.minor = ggplot2::element_blank(),
                   strip.background = ggplot2::element_rect(fill = "grey92", colour = NA))

  ggplot2::ggsave(path, plot = p, width = width,
                  height = max(2.4, height * length(spei_names)), dpi = 150)
  path
}
