
# Configuration and Setup
config <- list(
  input_dir = "~/Projects/data-mining-project/input",
  date_range = list(
    start = "2015-01-01",
    end = "2020-01-01"
  ),
  city_mapping = data.frame(
    air_quality = c("Bengaluru", "Delhi", "Hyderabad", "Jaipur", "Mumbai"),
    weather = c("bengaluru", "delhi", "hyderabad", "jaipur", "bombay")
  ),
  model_params = list(
    train_split = 0.8,
    cv_folds = 5,
    ntrees = 100,
    mtry_values = c(2, 3, 4)
  )
)

# Load required libraries
load_libraries <- function() {
  required_packages <- c(
    "ggplot2", "dplyr", "readr", "magrittr", "tidyr", "corrplot",
    "caret", "lubridate", "gridExtra", "zoo", "randomForest"
  )
  for (pkg in required_packages) {
    if (!require(pkg, character.only = TRUE)) {
      install.packages(pkg)
      library(pkg, character.only = TRUE)
    }
  }
}

# Data Loading Functions
load_air_quality_data <- function(input_dir, city_mapping, date_end) {
  data <- read_csv(
    file.path(input_dir, "air_quality", "city_hour.csv"),
    show_col_types = FALSE
  ) %>%
    filter(
      City %in% city_mapping$air_quality,
      Datetime < as.POSIXct(date_end)
    )

  print_missing_values(data, "Air Quality Data")
  data
}

load_weather_data <- function(input_dir, city_mapping, date_range) {
  weather_data <- lapply(city_mapping$weather, function(city) {
    file_path <- file.path(input_dir, "weather", paste0(city, ".csv"))
    data <- read_csv(file_path, show_col_types = FALSE)
    data$City <- city_mapping$air_quality[city_mapping$weather == city]
    data
  }) %>%
    bind_rows() %>%
    filter(
      date_time >= as.POSIXct(date_range$start),
      date_time < as.POSIXct(date_range$end)
    )

  print_missing_values(weather_data, "Weather Data")
  weather_data
}

# Feature Engineering Functions
create_temporal_features <- function(data) {
  data %>%
    mutate(
      hour_of_day = factor(as.numeric(format(Datetime, "%H"))),
      hour_cos = cos(2 * pi * as.numeric(hour_of_day) / 24),
      hour_sin = sin(2 * pi * as.numeric(hour_of_day) / 24),
      day_of_week = factor(as.numeric(format(Datetime, "%u"))),
      month_of_year = factor(as.numeric(format(Datetime, "%m")))
    )
}

create_weather_features <- function(data) {
  data %>%
    mutate(
      winddir_cos = cos(2 * pi * winddirDegree / 360),
      winddir_sin = sin(2 * pi * winddirDegree / 360),
      sunrise_normalized = normalize_column(sunrise),
      precipMM_cumsum_24h = calculate_rolling_sum(precipMM, City, 24),
      windspeedKmph_cumsum_24h = calculate_rolling_sum(windspeedKmph, City, 24)
    )
}

# Utility Functions
normalize_column <- function(x) {
  x_numeric <- as.numeric(x)
  (x_numeric - min(x_numeric, na.rm = TRUE)) /
    (max(x_numeric, na.rm = TRUE) - min(x_numeric, na.rm = TRUE))
}

calculate_rolling_sum <- function(x, group, window) {
  ave(x, group, FUN = function(y) {
    rollapply(y,
      width = window, FUN = sum, align = "right",
      fill = NA, na.rm = TRUE
    )
  })
}

print_missing_values <- function(data, dataset_name) {
  cat("\nMissing values in", dataset_name, ":\n")
  missing <- colMeans(is.na(data)) * 100
  print(round(missing[missing > 0], 2))
}

# Modeling Functions
prepare_model_data <- function(data, target_var, predictors) {
  data %>%
    filter(!is.na(!!sym(target_var)) & !!sym(target_var) > 0) %>%
    mutate(
      target_log = log(!!sym(target_var))
    ) %>%
    select(all_of(c("target_log", "City", predictors)))
}

plot_predictions <- function(predictions, city, target_var) {
  ggplot(predictions, aes(x = actual, y = predicted)) +
    geom_point(alpha = 0.3) +
    geom_abline(slope = 1, intercept = 0, color = "red", linetype = "dashed") +
    theme_minimal() +
    labs(
      title = paste("Actual vs Predicted", target_var, "-", city),
      x = paste("Actual", target_var),
      y = paste("Predicted", target_var)
    ) +
    coord_cartesian(
      xlim = c(0, max(predictions$actual)),
      ylim = c(0, max(predictions$predicted))
    )
}

# Modify prepare_model_data to be dynamic
prepare_model_data <- function(data, target_var, predictors) {
  target_sym <- sym(target_var)
  
  data %>%
    filter(!is.na(!!target_sym) & !!target_sym > 0) %>%
    select(all_of(c(target_var, "City", predictors))) %>%
    group_by(City) %>%
    mutate(across(all_of(predictors), ~ifelse(is.na(.), median(., na.rm = TRUE), .))) %>%
    ungroup() %>%
    mutate(target_log = log(!!target_sym)) %>%
    select(-!!target_sym) %>%
    na.omit()  # Remove any remaining rows with NAs
}

# Main Execution

load_libraries()

# Load and prepare data
air_quality <- load_air_quality_data(
  config$input_dir,
  config$city_mapping,
  config$date_range$end
)

weather <- load_weather_data(
  config$input_dir,
  config$city_mapping,
  config$date_range
)

# Merge and engineer features
data <- inner_join(
  air_quality,
  weather,
  by = c("City", "Datetime" = "date_time")
) %>%
  create_temporal_features() %>%
  create_weather_features()

# Define model variables
predictors <- c(
  "FeelsLikeC", "winddir_cos", "winddir_sin",
  "sunrise_normalized", "precipMM_cumsum_24h",
  "windspeedKmph_cumsum_24h"
)

target_var = "PM10"

# Prepare modeling data
model_data <- prepare_model_data(data, target_var, predictors)

# Split data
set.seed(123)
train_idx <- createDataPartition(
  model_data$target_log,
  p = config$model_params$train_split,
  list = FALSE
)
train_data <- model_data[train_idx, ]
test_data <- model_data[-train_idx, ]

# Train and evaluate models for each city
train_city <- function(city, train_data, test_data, predictors, target_var, model_params) {
  # Filter data for specific city
  train_city_data <- train_data %>% 
    filter(City == city) %>% 
    select(-City)
  
  test_city_data <- test_data %>% 
    filter(City == city) %>% 
    select(-City)
  
  # Error checking
  if (nrow(train_city_data) == 0) {
    stop(paste("No training data available for city:", city))
  }
  
  if (any(sapply(train_city_data, function(x) all(is.na(x))))) {
    stop("One or more columns contain all NA values")
  }
  
  # Train model
  model <- train(
    target_log ~ .,
    data = train_city_data,
    method = "rf",
    trControl = trainControl(
      method = "cv",
      number = model_params$cv_folds
    ),
    tuneGrid = expand.grid(mtry = model_params$mtry_values),
    ntree = model_params$ntrees
  )
  
  # Make predictions and evaluate
  pred_log <- predict(model, newdata = test_city_data)
  pred <- exp(pred_log)
  actual <- exp(test_city_data$target_log)
  
  # Calculate metrics
  evaluation <- list(
    metrics = data.frame(
      City = city,
      RMSE = RMSE(pred, actual),
      R2 = R2(pred, actual)
    ),
    predictions = data.frame(
      actual = actual,
      predicted = pred
    )
  )
  
  list(
    model = model,
    evaluation = evaluation
  )
}


bangalore_results = train_city("Bengaluru", train_data, test_data, predictors, target_var, config$model_params)
bangalore_plot <- plot_predictions(bangalore_results$evaluation$predictions, "Bengaluru", target_var)
bangalore_plot


delhi_results = train_city("Delhi", train_data, test_data, predictors, target_var, config$model_params)
delhi_plot <- plot_predictions(delhi_results$evaluation$predictions, "Delhi", target_var)
delhi_plot


hyderabad_results = train_city("Hyderabad", train_data, test_data, predictors, target_var, config$model_params)
hyderabad_plot <- plot_predictions(hyderabad_results$evaluation$predictions, "Hyderabad", target_var)
hyderabad_plot


jaipur_results = train_city("Jaipur", train_data, test_data, predictors, target_var, config$model_params)
jaipur_plot <- plot_predictions(jaipur_results$evaluation$predictions, "Jaipur", target_var)
jaipur_plot


mumbai_results = train_city("Mumbai", train_data, test_data, predictors, target_var, config$model_params)
mumbai_plot <- plot_predictions(mumbai_results$evaluation$predictions, "Mumbai", target_var)
mumbai_plot


# Combine all metrics
all_metrics <- rbind(
  bangalore_results$evaluation$metrics,
  delhi_results$evaluation$metrics,
  hyderabad_results$evaluation$metrics,
  jaipur_results$evaluation$metrics,
  mumbai_results$evaluation$metrics
)

# Calculate average metrics
average_metrics <- data.frame(
  City = "Average",
  RMSE = mean(all_metrics$RMSE),
  R2 = mean(all_metrics$R2)
)

# Combine with individual metrics
final_metrics <- rbind(all_metrics, average_metrics)

# Create combined plot
all_predictions <- rbind(
  data.frame(bangalore_results$evaluation$predictions, City = "Bengaluru"),
  data.frame(delhi_results$evaluation$predictions, City = "Delhi"),
  data.frame(hyderabad_results$evaluation$predictions, City = "Hyderabad"),
  data.frame(jaipur_results$evaluation$predictions, City = "Jaipur"),
  data.frame(mumbai_results$evaluation$predictions, City = "Mumbai")
)

combined_plot <- ggplot(all_predictions, aes(x = actual, y = predicted, color = City)) +
  geom_point(alpha = 0.3) +
  geom_abline(slope = 1, intercept = 0, color = "black", linetype = "dashed") +
  theme_minimal() +
  labs(
    title = paste("Actual vs Predicted", target_var, "- All Cities"),
    x = paste("Actual", target_var),
    y = paste("Predicted", target_var)
  ) +
  facet_wrap(~City)

# Print results
print(final_metrics)
print(combined_plot)
