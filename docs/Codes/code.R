############################################################################################################
##
##  CODE to replicate the results of the EMPIRICAL APPLICATION in the paper:
##      "LOSING CONTROL (GROUP)? THE MACHINE LEARNING CONTROL METHOD FOR COUNTERFACTUAL FORECASTING"
##
##  AUTHORS: Augusto Cerqua*, Marco Letta*, Fiammetta Menchetti**  
##                                                            
##  DATE: October 2023 
##
##  *(Sapienza University of Rome), **(University of Florence)
##
############################################################################################################

rm(list=ls())
set.seed(25092023)

# Instructions: Change the working directory below (it must be the path to the replication package, 
# something like "C:/.../Replication package") and then click 'Source'. The code runs independently.
# The code takes approximately [20] min to run

# ------------- Change working directory here ---------------------------------------------------------

wd <- "C:/Users/fiamm/Documents/MLCM/Replication package" 
setwd(wd)

# -----------------------------------------------------------------------------------------------------
old <- Sys.time()
##################################################################################################
## 0. Libraries, Functions & Data loading
##################################################################################################

### Libraries
library(CAST)
library(caret)
library(gbm)
library(elasticnet)
library(pls)
library(stats)
library(utils)
library(randomForest)
library(rpart)

### Custom functions
source(paste0(wd, "/Functions/package.R"))

### Data loading
# Full dataset
dataset_full <- read.csv(paste0(wd, "/Data/dataset_2016-2020_change_SLL_fixed_Invalsi_mat_std.csv"), na.strings=c("",".","NA"))
x.cate <- read.csv(paste0(wd, "/Data/CATE Dataset_updated.csv"), sep = ";")
# Pre-intervention dataset
dataset_pre_2020 <- subset(dataset_full, year<2020) 
# Intervention date
int_date <- 2020

# Comment: this is a 579 X 4 panel dataset (i.e., the number of units in the panel is 579
#          the number of times is 4). The dataset is organized in a a long manner
#          i.e., it has 579 X 4 = 2316 rows, one column for ID variable ('cod_sll2011'), 
#          one column for the time variable ('year') and one column for the dependent 
#          variable ('punt_wle_medio_mat5'). The dataset also contains 154 potential 
#          explanatory variables. 

##################################################################################################
## 1. Preliminary Random Forest
##################################################################################################

# Comment: this step is necessary to select the covariates that are most predictive of the
#          dependent variable in the pre-intervention period.  After the preliminary random forest,  
#          we rank the covariates based on their variable importance and perform a Panel Cross
#          Validation (PCV) to select the 'cutoff value' for the variable importance. See next step.
      
### 1.1. Settings
mtry <- ((ncol(dataset_pre_2020)-1)/3)
tunegrid <- expand.grid(.mtry=mtry)
ind <- which(colnames(dataset_pre_2020) %in% c("year", "cod_sll2011"))

### 1.2. Random Forest
preliminary_rf <- train(punt_wle_medio_mat5 ~ .,
                        data = dataset_pre_2020[ , -ind],
                        method = "rf",
                        metric = "RMSE",
                        trControl = trainControl(method="none"),
                        tuneGrid=tunegrid, 
                        ntree = 1000)

### 1.3. Variable importance
rf_Imp <- varImp(preliminary_rf, scale = TRUE)
importance <- data.frame(var = rownames(rf_Imp$importance), rf_Imp$importance)
importance <- importance[order(importance[, 2], decreasing = T),]

##################################################################################################
##  2. Panel Cross Validation
##################################################################################################

# Comment: Shall we retain the covariates with a variable importance greater than 6, 10 or 20? 
#          Based on the PCV we will choose the threshold (and thus the number of covariates to 
#          include in the data) that minimizes the RMSE in the prediction of the pre-intervention Y.

### 2.1. Setting thresholds of variable importance
num_cov <- c(5,10)

### 2.2. Setting the tuning parameters of the Machine Learning algorithms 
# SGB
gbmGrid <-  expand.grid(interaction.depth = c(1, 2, 3), 
                        n.trees=c(1000, 1500), 
                        shrinkage = c(0.002, 0.005, 0.01),
                        n.minobsinnode = c(10, 15, 20))
bo <- list(method = "gbm",
           tuneGrid = gbmGrid)
# RF
rf <- list(method = "rf",
           ntree = 1000)
# LASSO
lassoGrid <- expand.grid(fraction = seq(0.1, 0.9, by = 0.1))
lasso <- list(method = "lasso",
              tuneGrid = lassoGrid,
              preProc = c("center", "scale"))
# PLS
pls <- list(method = "pls")

### 2.3. Applying Panel Cross Validation to select the best importance threshold and the best
###      performing algorithm based on the RMSE criterion. Note that we include here the whole dataset
###      because the 'PanelCrossValidation' function subsets the data internally via the argument 
###      'int_date'. See lines 202 and beyond of 'package.R'.
PCV <- lapply(num_cov, FUN = function(x){
  
  xvar <- importance$var[1:x] ;
  data <- as.PanelMLCM(y = dataset_full[, "punt_wle_medio_mat5"], 
                       timevar = dataset_full[, "year"], 
                       id = dataset_full[, "cod_sll2011"],
                       x = dataset_full[, xvar], y.lag = 0) ;
  rfGrid <- expand.grid(mtry = round(c(ncol(data)/2, ncol(data)/3, ncol(data)/6))) ;
  plsGrid <- expand.grid(ncomp = seq(1, (ncol(data)-2), by = 1)) ;
  rf$tuneGrid <- rfGrid ;
  pls$tuneGrid <- plsGrid ;
  PCV <- PanelCrossValidation(data = data, int_date = int_date, ML_methods = list(bo, rf, lasso, pls)) ;
  return(PCV)
})

metrics <- sapply(PCV, FUN = function(x)(x$best.metric))
ind <- which(metrics == min(metrics))
best <- PCV[[ind]]$best

# Comment: with respect to the variable importance threshold, selecting covariates with an importance
#          greater than 6.4 minimizes the RMSE of the predicted Y in the pre-intervention period and 
#          the best performing algorithm at this threshold is Random Forest (check with best$method)

##################################################################################################
##  3. Causal effect estimation
##################################################################################################

### 3.1. Definition of the final dataset, based on the selected variable importance threshold
xvar <- importance$var[1:num_cov[ind]]
data <- as.PanelMLCM(y = dataset_full[, "punt_wle_medio_mat5"], 
                     timevar = dataset_full[, "year"], 
                     id = dataset_full[, "cod_sll2011"],
                     x = dataset_full[, xvar], y.lag = 0) 

### 3.2. Causal effect estimation
causal_effects <- MLCM(data = data, int_date = int_date, inf_type = "block", PCV = best,
                       nboot = 1000, CATE = TRUE, x.cate = x.cate)

# ATE
ate_eff <- c(causal_effects$ate, causal_effects$conf.ate)
names(ate_eff) <- c("ATE", "Lower_bound", "Upper_bound")
# Individual effects
ind_eff <- data.frame(causal_effects$ind.effects, 
                      confint = t(causal_effects$conf.individual[,,1]))
names(ind_eff) <- c("IND_EFF", "Lower_bound", "Upper_bound")
ind_eff$is.signif <- as.numeric(!(0 >= ind_eff$Lower_bound & 0 <= ind_eff$Upper_bound))
# CATE
cate_eff <- causal_effects$cate.inf

##################################################################################################
##  4. Savings
##################################################################################################

write.csv(ind_eff, file = paste0(wd, "/Output/individual_effects.csv"))
write.csv(ate_eff, file = paste0(wd, "/Output/ate.csv"))
write.csv(cate_eff, file = paste0(wd, "/Output/cate.csv"))

new <- Sys.time()
new - old