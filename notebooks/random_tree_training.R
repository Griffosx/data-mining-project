library(ggplot2)
library(googledrive)
library(dplyr, warn.conflicts = FALSE)
library(readr)
library(magrittr)
library(tidyr, warn.conflicts = FALSE)
library(corrplot)
library(caret)
library(lubridate, warn.conflicts = FALSE)
library(gridExtra, warn.conflicts = FALSE)
library(zoo)
library(randomForest)

# ================================
# Loading Data
# ================================

INPUT_DIR <- "~/Projects/data-mining-project/input"

city_name_map <- data.frame(
  air_quality = c("Bengaluru", "Delhi", "Hyderabad", "Jaipur", "Mumbai"),
  weather = c("bengaluru", "delhi", "hyderabad", "jaipur", "bombay")
)

# load the air quality data
data_air_quality <- read_csv(
  file.path(INPUT_DIR, "air_quality", "city_hour.csv"),
  show_col_types = FALSE
)

# filter the data for the cities of interest
data_air_quality <- data_air_quality %>%
  filter(City %in% city_name_map$air_quality) %>%
  filter(Datetime < as.POSIXct("2020-01-01"))

summary(data_air_quality)

# % of NA by column
cat("NA values by column:\n")
sapply(data_air_quality, function(x) sum(is.na(x)) / length(x))


# load the weather data from multiple CSV files
data_weather <- list()

for (city in city_name_map$weather) {
  file_path <- file.path(INPUT_DIR, "weather", paste0(city, ".csv"))
  this_data <- read_csv(file_path, show_col_types = FALSE)
  this_data$City <- city_name_map$air_quality[city_name_map$weather == city]
  data_weather[[length(data_weather) + 1]] <- this_data
  
  # cat(paste("Loaded weather data for city", city, "\n"))
}

data_weather <- bind_rows(data_weather)

# filter the data
data_weather <- data_weather %>%
  filter(date_time >= as.POSIXct("2015-01-01")) %>%
  filter(date_time < as.POSIXct("2020-01-01"))

summary(data_weather)

# ================================
# Feature engineering
# ================================


# merge the air quality and weather data
data_merged <- inner_join(
  data_air_quality,
  data_weather,
  by = c("City", "Datetime" = "date_time")
)

# create a new variable for the hour of the day
data_merged$hour_of_day <- as.numeric(format(data_merged$Datetime, "%H"))
data_merged$hour_cos <- cos(2 * pi * data_merged$hour_of_day / 24)
data_merged$hour_sin <- sin(2 * pi * data_merged$hour_of_day / 24)
data_merged$hour_of_day <- factor(data_merged$hour_of_day)

# create a new variable for the day of the week
data_merged$day_of_week <- as.numeric(format(data_merged$Datetime, "%u"))
data_merged$day_of_week <- factor(data_merged$day_of_week)

# create a new variable for the month of the year
data_merged$month_of_year <- as.numeric(format(data_merged$Datetime, "%m"))
data_merged$month_of_year <- factor(data_merged$month_of_year)

# convert wind direction to a sin-cos pair
data_merged$winddir_cos <- cos(2 * pi * data_merged$winddirDegree / 360)
data_merged$winddir_sin <- sin(2 * pi * data_merged$winddirDegree / 360)

# convert the City variable to a factor
data_merged$City <- factor(data_merged$City)

# Sunrise normalization:
sunrise_numeric <- as.numeric(data_merged$sunrise)
sunrise_min <- min(sunrise_numeric)
sunrise_max <- max(sunrise_numeric)
data_merged$sunrise_normalized <- 
  (sunrise_numeric - sunrise_min) / (sunrise_max - sunrise_min)


# Create cumulative sum for precipMM
data_merged$precipMM_cumsum_24h <- ave(
  data_merged$precipMM,
  data_merged$City,
  FUN = function(x) rollapply(x, width = 24, FUN = sum, align = "right", fill = NA, na.rm = TRUE)
)

# Create cumulative sum for windspeedKmph
data_merged$windspeedKmph_cumsum_24h <- ave(
  data_merged$windspeedKmph,
  data_merged$City,
  FUN = function(x) rollapply(x, width = 24, FUN = sum, align = "right", fill = NA, na.rm = TRUE)
)

View(data_merged)


# ================================
# Predicting PM10 Including City Using R
# ================================

summary(data_merged$City)

# Select Relevant Features Including 'City'
predictors <- c("City", "FeelsLikeC", "winddir_cos", "winddir_sin", 
                "sunrise_normalized", "precipMM_cumsum_24h", 
                "windspeedKmph_cumsum_24h")
target <- "PM10"

data_model <- data_merged %>%
  select(all_of(c(target, predictors)))

summary(data_model)

# Handle Missing Values

# Check for missing values
missing_summary <- sapply(data_model, function(x) sum(is.na(x)))
print("Missing Values in Each Column:")
print(missing_summary)

# Remove rows with missing target or predictors
data_model_clean <- data_model %>%
  filter(!is.na(PM10) & !is.na(City)) %>%
  # Optionally, impute other missing predictor values
  mutate(across(-c(PM10, City), ~ ifelse(is.na(.), median(., na.rm = TRUE), .)))
# Check again for missing values
missing_summary_clean <- sapply(data_model_clean, function(x) sum(is.na(x)))
print("Missing Values in Each Column after purge:")
print(missing_summary_clean)

# Convert 'City' to Factor
data_model_clean$City <- as.factor(data_model_clean$City)

# Exploratory Data Analysis (Optional)
ggplot(data_model_clean, aes(x = PM10)) +
  geom_histogram(binwidth = 10, fill = "skyblue", color = "black") +
  theme_minimal() +
  labs(title = "Distribution of PM10", x = "PM10", y = "Frequency")

# Split the Data into Training and Testing Sets
set.seed(123)
train_index <- createDataPartition(data_model_clean$PM10, p = 0.8, list = FALSE)
train_data <- data_model_clean[train_index, ]
test_data  <- data_model_clean[-train_index, ]

# Train Predictive Models

# Define Train Control with Reduced Cross-Validation
train_control <- trainControl(
  method = "cv",
  number = 3,              # Fewer folds for faster training
  verboseIter = FALSE,     # Disable verbose output
  allowParallel = FALSE    # Ensure single-core processing
)

# Train Random Forest Model with Limited Tuning
rf_model <- train(
  PM10 ~ ., 
  data = train_data, 
  method = "rf",
  trControl = train_control,
  tuneGrid = data.frame(mtry = floor(sqrt(ncol(train_data) - 1))),
  ntree = 100 # Set number of trees to reduce computation
)

# Make Predictions on Test Set
rf_predictions <- predict(rf_model, newdata = test_data)

# Define Evaluation Function
evaluate_model <- function(actual, predicted, model_name) {
  rmse_val <- RMSE(pred = predicted, obs = actual)
  r2_val <- R2(pred = predicted, obs = actual)
  cat(sprintf("%s - RMSE: %.2f, R²: %.2f\n", model_name, rmse_val, r2_val))
}

# Evaluate and Print Model Performance
cat("Model Performance on Test Set:\n")
evaluate_model(test_data$PM10, rf_predictions, "Random Forest")

## Plot Random Forest predictions
ggplot(test_data, aes(x = PM10, y = rf_predictions)) +
  geom_point(color = "green", alpha = 0.05) +
  geom_abline(slope = 1, intercept = 0, color = "red") +
  theme_minimal() +
  labs(title = "Random Forest: Actual vs Predicted PM10",
       x = "Actual PM10",
       y = "Predicted PM10")

# Feature Importance (Random Forest)
importance_rf <- varImp(rf_model, scale = FALSE)
print("Random Forest Feature Importance:")
print(importance_rf)

# Plot Feature Importance
plot(importance_rf, main = "Feature Importance - Random Forest")


