# ---------------------------------------------------------------------------
# climate-indices | Figures
# ---------------------------------------------------------------------------

#' Faceted time series of a standardised index at every computed scale.
#'
#' One bar per month. An area fill would interpolate across zero crossings and
#' draw polygons that are not in the data.
plot_index_panels <- function(monthly, index_names, path,
                              ylab = "Index (standard deviations)",
                              title = NULL, width = 10, panel_height = 2.0) {
  long <- do.call(rbind, lapply(index_names, function(nm) {
    data.frame(Date  = monthly$Date,
               Scale = factor(nm, levels = index_names,
                              labels = paste(sub("^[A-Za-z]+_", "", index_names), "month")),
               Value = monthly[[nm]],
               stringsAsFactors = FALSE)
  }))
  long <- long[is.finite(long$Value), , drop = FALSE]
  long$Sign <- ifelse(long$Value < 0, "Dry", "Wet")

  p <- ggplot2::ggplot(long, ggplot2::aes(x = Date, y = Value)) +
    ggplot2::geom_hline(yintercept = 0, colour = "grey40", linewidth = 0.3) +
    ggplot2::geom_hline(yintercept = c(-1, 1), colour = "grey70",
                        linetype = "dashed", linewidth = 0.3) +
    ggplot2::geom_col(ggplot2::aes(fill = Sign), width = 31) +
    ggplot2::scale_fill_manual(values = c(Dry = "#b2182b", Wet = "#2166ac"),
                               name = NULL) +
    ggplot2::facet_wrap(~Scale, ncol = 1, strip.position = "right") +
    ggplot2::labs(x = NULL, y = ylab, title = title) +
    ggplot2::theme_bw(base_size = 10) +
    ggplot2::theme(legend.position = "top",
                   panel.grid.minor = ggplot2::element_blank(),
                   strip.background = ggplot2::element_rect(fill = "grey92", colour = NA))

  ggplot2::ggsave(path, plot = p, width = width,
                  height = max(2.4, panel_height * length(index_names)), dpi = 150)
  path
}

# Kept for callers written against v1.0.0.
plot_spei_panels <- function(monthly, spei_names, path, width = 10, height = 2.0) {
  plot_index_panels(monthly, spei_names, path,
                    ylab = "SPEI (standard deviations)",
                    width = width, panel_height = height)
}
