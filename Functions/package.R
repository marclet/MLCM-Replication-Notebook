#' Machine Learning Control Method
#'
#' This function is the main workhorse of the package 'MachineControl'. It takes as
#' input a panel dataset, i.e., multiple units observed at several points in time and
#' exposed simultaneously to some policy (indicated by int_date). It then performs
#' the Panel Cross Validation (PCV) by comparing the predictive performance of several Machine
#' Learning (ML) methods in the pre-intervention periods and then outputs the estimated
#' Average Treatment Effect (ATE) of the policy and its confidence interval estimated by
#' bootstrap. Details on the causal assumptions, the estimation process and inference
#' can be found in Cerqua A., Letta M., and Menchetti F. (2023). The method is especially
#' suited when there are no control units available, but if there are control units these
#' can be easily added as control series among the covariates.
#'
#'
#' @param data        A panel dataset in long form, having one column for the time variable, one column for the units'
#'                    unique IDs, one column for the outcome variable and one or more columns for the covariates.
#' @param int_date    The date of the intervention, treatment, policy introduction or shock. It must be contained in 'timevar'.
#'                    By default, this is the first period that the causal effect should be computed for. See Details.
#' @param inf_type    Character, type of inference to be performed. Possible choices are 'classic', 'block', 'bc classic', 'bc block', 'bca'
#' @param y           Character, name of the column containing the outcome variable. It can be omitted for \code{PanelMLCM} objects.
#' @param timevar     Character, name of the column containing the time variable. It can be omitted for \code{PanelMLCM} objects.
#' @param id          Character, name of the column containing the ID's. It can be omitted for \code{PanelMLCM} objects.
#' @param y.lag       Optional, number of lags of the dependent variable to include in the model. Defaults to zero.
#' @param nboot       Number of bootstrap replications, defaults to 1000.
#' @param pcv_block   Number of pre-intervention times to block for panel cross validation. Defaults to 1, see Details.
#' @param metric      Character, the performance metric that should be used to select the optimal model.
#'                    Possible choices are either \code{"RMSE"} (the default) or \code{"Rsquared"}.
#' @param PCV         Optional, best performing ML method as selected from a previous call to \code{PanelCrossValidation}.
#' @param CATE        Whether the function should estimate also CATE (defaults to \code{FALSE}). See Details.
#' @param x.cate      Optional matrix or data.frame of external regressors to use as predictors of CATE. If missing, the
#'                    same covariates used to estimate ATE will be used. See details.
#' @param alpha       Confidence interval level to report for the ATE. Defaulting to 0.05 for a two sided
#'                    95\% confidence interval.

MLCM <- function(data, int_date, inf_type, y = NULL, timevar = NULL, id = NULL, y.lag = 0, nboot = 1000, pcv_block = 1, metric = "RMSE", PCV = NULL, CATE = FALSE, x.cate = NULL, alpha = 0.05){

  ### Parameter checks
  if(!any(class(data) %in% c("matrix", "data.frame", "PanelMLCM"))) stop("data must be a matrix, a data.frame or a PanelMLCM object")
  if(!"PanelMLCM" %in% class(data) & any(c(is.null(y), is.null(timevar), is.null(id)))) stop("Unspecified columns in 'matrix' or 'data.frame' data")
  if(!(is.null(y) | class(y) == "character")) stop("y must be a character")
  if(!(is.null(timevar) | class(timevar) == "character")) stop("timevar must be a character")
  if(!(is.null(id) | class(id) == "character")) stop("id must be a character")
  if(!is.numeric(y.lag) | y.lag < 0 ) stop("y.lag must be numeric and strictly positive")  # should be integer
  if(!is.null(y)){if(!y %in% colnames(data)) stop (paste("there is no column called", y, "in 'data'"))}
  if(!is.null(timevar)){if(!timevar %in% colnames(data)) stop (paste("there is no column called", timevar, "in 'data'"))}
  if(!is.null(id)){if(!id %in% colnames(data)) stop (paste("there is no column called", id, "in 'data'"))}
  if(!any(class(int_date) %in% c("Date", "POSIXct", "POSIXlt", "POSIXt", "numeric", "integer"))) stop("int_date must be integer, numeric or Date")
  if(is.null(timevar)){if(!int_date %in% data[, "Time"]) stop ("int_date must be contained in the 'Time' column")}
  if(!is.null(timevar)){if(!int_date %in% data[, timevar]) stop ("int_date must be contained in timevar")}
  if(!any(inf_type %in% c("classic", "block", "bc classic", "bc block", "bca"))) stop("Inference type not allowed, check the documentation")
  if(nboot < 1 | all(!class(nboot) %in% c("numeric", "integer")) | nboot%%1 != 0) stop("nboot must be an integer greater than 1")
  if(!metric %in% c("RMSE", "Rsquared")) stop("Metric not allowed, check documentation")
  if(!is.null(PCV)){if(!"train" %in% class(PCV)) stop ("Invalid PCV method, it should be an object of class 'train'")}
  if(alpha < 0 | alpha > 1) stop("Invalid confidence interval level, alpha must be positive and less than 1")
  if(CATE & !is.null(x.cate)){

    x.cate <- check_xcate(x.cate = x.cate, data = data, id = id, timevar = timevar)

  } else if (!is.null(x.cate) & !CATE){ stop("Inserted external data for CATE estimation but 'CATE' is set to FALSE")}

  ### Structuring the panel dataset in the required format
  if("PanelMLCM" %in% class(data)){

    data_panel <- data

  } else {

    data_panel <- as.PanelMLCM(y = data[, y], timevar = data[, timevar], id = data[, id],
                               x = data[, !(names(data) %in% c(y, id, timevar))], y.lag = y.lag)

  }


  ### Panel cross-validation
  if(is.null(PCV)){

    best <- PanelCrossValidation(data = data_panel, int_date = int_date, pcv_block = pcv_block, metric = metric)$best

  } else {

    best <- PCV

  }

  ### Fit the best (optimized) ML algorithm on all pre-intervention data and make predictions in the post-intervention period
  ind <- which(data_panel[, "Time"] < int_date)
  set.seed(1)
  invisible(capture.output(
   fit <- train(Y ~ .,
                data = data_panel[ind, !(names(data_panel) %in% c("ID", "Time"))],
                method = best$method,
                metric = metric,
                trControl = trainControl(method="none"),
                tuneGrid = best$bestTune)
  ))

  ### ATE & individual effects estimation
  effects <- ate_est(data = data_panel, int_date = int_date, best = best, metric = metric, y.lag = y.lag, ran.err = FALSE)
  ate <- effects$ate
  ind_effects <- effects$ind_effects

  ### ATE & individual effects inference
  invisible(capture.output(

    boot_inf <- boot_ate(data = data_panel, int_date = int_date, bestt = best, type = inf_type, nboot = nboot, ate = ate,
                         alpha = alpha, metric = metric, y.lag = y.lag, ind.eff = ind_effects)

  ))

  ### CATE estimation & inference
  if(CATE){

    cate_effects <- cate_est(data = data_panel, int_date = int_date, ind_effects = ind_effects, x.cate = x.cate, nboot = nboot, alpha = alpha)
    cate <- cate_effects$cate
    cate.inf <- cate_effects$cate.inf

  } else {

    cate <- NULL
    cate.inf <- NULL
  }


  ### Saving results
  return(list(best_method = best, fit = best, ate = ate, var.ate = boot_inf$var.ate, conf.ate = boot_inf$conf.ate,
              ind.effects = ind_effects, conf.individual = boot_inf$conf.individual, cate = cate, cate.inf = cate.inf))

}
#' Structuring the panel dataset
#'
#' This function takes as input the panel dataset given by the user and changes the
#' ordering and the names of the columns to obtain an object of class 'PanelMLCM'
#' to be used by the function 'MLCM'.
#'
#' @param y Numeric, the outcome variable.
#' @param x Matrix or data.frame of covariates to include in the model.
#' @param timevar  The column containing the time variable. It can be numeric, integer or
#'                 a date object
#' @param id Numeric, the column containing the ID's.
#' @param y.lag Optional, number of lags of the dependent variable to include in the model.
#'

as.PanelMLCM <- function(y, x, timevar, id, y.lag = 0){

  # Parameter checks
  if(!(is.numeric(y) & length(y)>1)) stop("y must be a numeric vector of length greater than 1")
  if(!any(class(x) %in% c("numeric", "matrix", "data.frame"))) stop("x must be a vector, matrix or data.frame")
  if(NROW(x) != length(y)) stop("NROW(x) != length(y)")
  if(!any(class(timevar) %in% c("Date", "POSIXct", "POSIXlt", "POSIXt", "integer", "numeric")) | length(timevar) != length(y)) stop("timevar must be a numeric vector or a 'Date' object of the same length as y")
  if(!(is.numeric(id) & length(id) == length(y))) stop("id must be a numeric vector of the same length as y")
  if(length(unique(id))*length(unique(timevar)) != length(y)) warning("The panel is unbalanced")
  if(!is.numeric(y.lag) | y.lag < 0 ) stop("y.lag must be numeric and strictly positive")
  if(length(unique(timevar)) <= y.lag) stop("The number of selected lags is greater or equal to the number of times, resulting in an empty dataset")

  ### STEP 1. Structuring the panel dataset
  panel <- data.frame(Time = timevar, ID = id, Y = y, x)

  ### STEP 2. Are there any past lags of 'y' to include?
  if(y.lag > 0){

    # Applying the internal '.true_lag' function to the Y variable of each unit in the panel
    ids <- unique(id)
    ylags <- sapply(1:y.lag, function(l){unlist(lapply(ids, function(x)(.true_lag(y[id == x], l))))})
    colnames(ylags) <- paste0("Ylag", 1:y.lag)
    panel <- data.frame(panel, ylags)

    # Removing initial NAs from the panel
    ind <- which(is.na(panel[, paste0("Ylag", y.lag)]))
    panel <- panel[-ind, ]

  }

  # Returning results
  class(panel) <- c("data.frame", "PanelMLCM")
  return(panel)
}

#' Panel Cross Validation
#'
#' This function implements the panel cross validation technique as described in
#' Cerqua A., Letta M. & Menchetti F., (2023) <https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4315389>.
#' It works as a rolling window training and testing procedure where the ML methods are trained recursively on the
#' the observations in the first $t$ time periods and tested in the prediction of the next periods.
#'
#' @param data A 'PanelMLCM' object from a previous call to \code{as.PanelMLCM}.
#' @param int_date The date of the intervention, treatment, policy introduction or shock.
#' @param pcv_block Number of pre-intervention times to block for panel cross validation. Defaults to 1, see Details.
#' @param metric Character, the performance metric that should be used to select the optimal model.
#'               Possible choices are either \code{"RMSE"} (the default) or \code{"Rsquared"}.
#' @param trControl Optional, used to customize the training step. It must be the output from a call to \code{trainControl} from the \code{caret} package.
#' @param ML_methods Optional list of ML methods to be used as alternatives to the default methods. Each method must be supplied
#'                   as a named list of two elements: a character defining the method name from all the ones available in \code{caret}
#'                   and the grid of parameter values to tune via the panel cross validation. See Details and the examples for additional explanations.#'
#' @return A list of class \code{train} with the best-performing ML method.
#'

PanelCrossValidation <- function(data, int_date, pcv_block = 1, metric = "RMSE", trControl = NULL, ML_methods = NULL){

  ### Parameter checks
  if(!any(class(data) %in% "PanelMLCM")) stop("Invalid class in the PanelCrossValidation function, something is wrong with as.PanelMLCM")
  if(!(int_date %in% data[, "Time"])) stop("int_date must be contained in timevar")
  if(sum(unique(data[, "Time"]) < int_date) - pcv_block < 1) stop("Panel cross validation must be performed in at least one time period")
  if(pcv_block <= 0) stop("The number of 'pcv_block' time periods for panel cross validation must be at least 1")
  if(!metric %in% c("RMSE", "Rsquared")) stop("Metric not allowed, check documentation")
  #if(is.list(ML_methods)){if(any(sapply(ML_methods, FUN = length) != 2)) stop("'ML_methods' must be a list of methods, each of length 2")}
  #if(is.list(ML_methods)){
  #  if(any(sapply(ML_methods, FUN = function(x)(any(!names(x) %in% c("method", "tuneGrid")))))) stop("Each method in 'ML_methods' must be a named list, check documentation")}

  ### STEP 1. The CAST package is used to generate separate testing sets for each year
  Tt <- length(unique(data[, "Time"]))
  indices <- CreateSpacetimeFolds(data, timevar = "Time", k = Tt)
  end <- sum(unique(data[, "Time"]) < (int_date - 1) )
  trainx <- lapply(pcv_block:end, FUN = function(x) unlist(indices$indexOut[1:x]))
  testx <- lapply(pcv_block:end, FUN = function(x) unlist(indices$indexOut[[x+1]]))

  ### STEP 2. Set control function by specifying the training and testing folds that caret will use
  ###         for cross-validation and tuning of the hyperparameters (i.e., the combination of folds defined above)
  if(is.null(trControl)){

    ctrl <- trainControl(index = trainx, indexOut = testx)

  } else {

    ctrl <- trControl # da capire come fare i param checks

  }


  ### STEP 3.  Tune the hyperparameters of each of the ML algorithms via temporal cross-validation

  if(is.null(ML_methods)){

    # STOCHASTIC GRADIENT BOOSTING
    gbmGrid <-  expand.grid(interaction.depth = c(1, 2, 3),
                            n.trees=c(500, 1000, 1500, 2000),
                            shrinkage = seq(0.01, 0.1, by = 0.01),
                            n.minobsinnode = c(10,20))

    set.seed(1)
    bo <- train(Y ~ .,
                data = data[, !(names(data) %in% c("ID", "Time"))],
                method = "gbm",
                metric = metric,
                trControl = ctrl,
                tuneGrid = gbmGrid,
                verbose = FALSE)

    # RANDOM FOREST
    set.seed(1)
    rf <- train(Y ~ .,
                data = data[, !(names(data) %in% c("ID", "Time"))],
                method = "rf",
                metric = metric,
                search = "grid",
                trControl = ctrl,
                tuneGrid = expand.grid(mtry = (2:(ncol(data)-3))),
                ntree=500)
    # LASSO
    lasso <- train(Y ~ .,
                   data = data[, !(names(data) %in% c("ID", "Time"))],
                   method = "lasso",
                   metric = metric,
                   trControl = ctrl,
                   tuneGrid = expand.grid(fraction = seq(0.1, 0.9, by = 0.1)),
                   preProc=c("center", "scale"))

    # PLS
    pls <- train(Y ~ .,
                 data = data[, !(names(data) %in% c("ID", "Time"))],
                 method = "pls",
                 metric = metric,
                 trControl = ctrl,
                 tuneGrid = expand.grid(ncomp = c(1:10)),
                 preProc=c("center", "scale"))

    # Storing results in a list
    m_list <- list(bo = bo, rf = rf, lasso = lasso, pls = pls)

  } else {

    invisible(capture.output(

    m_list <- lapply(ML_methods, FUN = function(x){set.seed(1); do.call(train, c(list(Y ~ .,
                                                                         data = data[, !(names(data) %in% c("ID", "Time"))],
                                                                         metric = metric,
                                                                         trControl = ctrl), x))})
    ))

  }


  ### STEP 4. Selecting the "best" ML algorithm based on the provided performance metric
  names(m_list) <- lapply(m_list, function(x)(x$method))
  rmse_min <- sapply(m_list, FUN = function(x) min(x$results[, metric]), simplify = T)
  ind <- which(rmse_min == min(rmse_min))

  ### Returning result
  return(list(best = m_list[[ind]], best.metric = min(rmse_min), all_methods = m_list))

}

#' Bootstrap inference for ATE
#'
#' Internal function, used within the MLCM routine for the estimation of ATE
#' standard error and 95% confidence interval.
#'
#' @param data A 'PanelMLCM' object from a previous call to \code{as.PanelMLCM}.
#' @param int_date    The date of the intervention, treatment, policy introduction or shock. It must be contained in 'timevar'.
#' @param bestt Object of class \code{train}, the best-performing ML method as selected
#'              by panel cross validation.
#' @param type Character, type of inference to be performed. Possible choices are 'classic', 'block', 'bc classic', 'bc block', 'bca'.
#' @param nboot Number of bootstrap replications.
#' @param alpha Confidence interval level to report for the ATE. Defaulting to 0.05 for a two sided
#'              95\% confidence interval
#' @param metric Character, the performance metric that should be used to select the optimal model.
#'               Possible choices are either \code{"RMSE"} (the default) or \code{"Rsquared"}.
#' @param ate Numeric, the estimated ATE in the sample.
#'
#' @return A list with the following components:
#' \itemize{
#'   \item \code{type}: the inference type that has been performed
#'   \item \code{ate.boot}: the bootstrap distribution for ATE
#'   \item \code{conf.ate}: bootstrap confidence interval at the 95% level
#'   \item \code{var.ate}: estimated variance for ATE
#'   \item \code{ate.lower}: lower confidence interval bound
#'   \item \code{ate.upper}: upper confidence interval bound
#' }


boot_ate <- function(data, int_date, bestt, type, nboot, alpha, metric, y.lag, ate = NULL, ind.eff = NULL){

  ### Param checks
  if(!any(class(data) %in% "PanelMLCM")) stop("Invalid class in the PanelCrossValidation function, something is wrong with as.PanelMLCM")
  # if(length(ind)<1) stop("A zero-length pre-intervention period was selected, please check your data and your definition of 'post_period'")
  if(!any(type %in% c("classic", "block", "bc classic", "bc block", "bca"))) stop("Inference type not allowed, check the documentation")
  if(nboot < 1 | all(!class(nboot) %in% c("numeric", "integer")) | nboot%%1 != 0) stop("nboot must be an integer greater than 1")
  if(alpha < 0 | alpha > 1) stop("Invalid confidence interval level, alpha must be positive and less than 1")
  if(!is.numeric(ate)) stop ("ATE must be numeric")


  ### Setting pre/post intervention periods
  pre <- which(data[, "Time"] < int_date)
  post <- which(data[, "Time"] >= int_date)

  ### Classic bootstrap
  if(type %in% c("classic", "bc classic", "bca")){

    # Step 1. Sampling the indices (time-id pairs)
    ii<- matrix(sample(pre, size = nboot*length(pre), replace = T), nrow = nboot, ncol = length(pre))

    # Step 2. Estimating individual effects and ATE for each bootstrap iteration
    # ate_boot <- apply(ii, 1, function(i){ate_est(data = data[c(i, post),], int_date = int_date, best = bestt, metric = metric, ran.err = TRUE, y.lag = y.lag)$ate})
    eff_boot <- apply(ii, 1, function(i){ate_est(data = data[c(i, post),], int_date = int_date, best = bestt, metric = metric, ran.err = TRUE, y.lag = y.lag)})
    ate_boot <- sapply(eff_boot, function(x)(x$ate))
    ind_boot <- sapply(eff_boot, function(x)(x$ind_effects))

  }

  ### Block bootstrap
  if(type %in% c("block", "bc block")){

    # Step 1. Sampling the units
    ids <- unique(data$ID)
    ind1 <- sapply(1:nboot, function(boot){set.seed(boot); sample(ids, size = length(ids), replace = TRUE)}, simplify = FALSE)

    # Step 2. Indices pre/post interventions corresponding to the sampled units
    ii0 <- sapply(ind1, FUN = function(x){

      unlist(sapply(x, function(y)(intersect(which(data[, "ID"] %in% y), pre)), simplify = FALSE))

    }, simplify = FALSE)

    #ii1 <- mapply(ind1, ii0, FUN = function(ind1, ii0){

    #  unlist(sapply(ind1, function(y)(setdiff(which(data[, "ID"] %in% y), ii0)), simplify = FALSE))

    #}, SIMPLIFY = FALSE)
    
    # Step 3. Estimating individual effects and ATE for each bootstrap iteration
    #ate_boot <- mapply(x = ii0, y = ii1, function(x, y){ate_est(data = data[c(x, y),], int_date = int_date, best = bestt, metric = metric, ran.err = TRUE, y.lag = y.lag)$ate})
    # ate_boot <- sapply(ii0, function(i){ate_est(data = data[c(i, post),], int_date = int_date, best = bestt, metric = metric, ran.err = TRUE, y.lag = y.lag)$ate})
    eff_boot <- lapply(ii0, function(i){ate_est(data = data[c(i, post),], int_date = int_date, best = bestt, metric = metric, ran.err = TRUE, y.lag = y.lag)})
    ate_boot <- sapply(eff_boot, function(x)(x$ate))
    ind_boot <- sapply(eff_boot, function(x)(x$ind_effects[,-1]))

  }

  ### Confidence interval for ATE
  ate_boot <- matrix(ate_boot, nrow = length(unique(data[post, "Time"])))
  rownames(ate_boot) <- unique(data[post, "Time"])
  conf.ate <- apply(ate_boot, 1, quantile, probs = c(alpha/2, 1 - alpha/2))
  var.ate <- apply(ate_boot, 1, var)
  
  ### Confidence interval for the individual effects
  conf.individual <- array(apply(ind_boot, 1, quantile, probs = c(0.025, 0.975)),
                           dim = c(2,length(unique(data$ID)), length(unique(data[post, "Time"]))))
  dimnames(conf.individual)[[3]] <- unique(data[post, "Time"])
  dimnames(conf.individual)[[1]] <- c("Lower", "Upper")
  
  ### Adjusting for bias and/or skewness (if 'type' is "bc classic", "bc block")
  if(type %in% c("bc classic", "bc block")){
    
    # Bias correction for ATE
    z0 <- mapply(x = apply(ate_boot, 1, as.list), y = ate, FUN = function(x,y)(qnorm(sum(x < y)/nboot)), SIMPLIFY = TRUE)
    lower <- pnorm(2*z0 + qnorm(alpha/2))
    upper <- pnorm(2*z0 + qnorm(1 - alpha/2))
    conf.ate <- mapply(x = as.list(lower), y = as.list(upper), z = apply(ate_boot, 1, as.list),
                       FUN = function(x,y,z){quantile(unlist(z), probs = c(x,y))}, SIMPLIFY = TRUE)
    # conf.ate <- quantile(mean_ate_boot, probs = c(lower, upper)) # old

    # Bias correction for the individual effects
    z0 <- mapply(x = apply(ind_boot, 1, as.list), y = ind.eff[,-1], FUN = function(x,y)(qnorm(sum(x < y)/nboot)), SIMPLIFY = TRUE)
    lower <- pnorm(2*z0 + qnorm(alpha/2))
    upper <- pnorm(2*z0 + qnorm(1 - alpha/2))
    conf.individual <- mapply(x = as.list(lower), y = as.list(upper), z = apply(ind_boot, 1, as.list),
                       FUN = function(x,y,z){quantile(unlist(z), probs = c(x,y))}, SIMPLIFY = TRUE)
    conf.individual <- array(conf.individual, c(2, length(unique(data$ID)), length(unique(data[post, "Time"]))))
    dimnames(conf.individual)[[3]] <- unique(data[post, "Time"])
    dimnames(conf.individual)[[1]] <- c("Lower", "Upper")
  }

  if(type == "bca"){ # RICONTROLLARE

    counts <- t(apply(ii, 1, FUN = function(x)(table(c(x, pre))-1)))
    Blist <- mapply(x = c(1,2,3), y = ate, FUN = function(x,y){
             list(Y = counts, tt = ate_boot[x, ], t0 = y)}, SIMPLIFY = FALSE)
    out2 <- mapply(B = Blist, FUN = bcajack2, MoreArgs = list(alpha = alpha), SIMPLIFY = FALSE)
    conf.ate <- sapply(out2, FUN = function(x)(x$lims[c(1,3), "bca"]))
    # Blist <- list(Y = counts, tt = colMeans(ate_boot), t0 = ate) # old
    # out2 <- bcajack2(B = Blist, alpha = alpha) # old
    # conf.ate <- out2$lims[c(1,3),"bca"] # old

  }


  # Returning results
  return(list(type = type, conf.ate = conf.ate, var.ate = var.ate, conf.individual = conf.individual))
  # return(list(type = type, conf.ate = conf.ate, var.ate = var.ate, ate.lower = conf.ate[1, ], ate.upper = conf.ate[2, ], conf.individual = conf.individual))
}

#' Bootstrap inference for CATE
#'
#' Internal function, used within the MLCM routine for the estimation of CATE
#' standard errors and 95% confidence intervals in each terminal node of the tree.
#' It works by resampling the observations at each final node of the tree.
#' Note that the observations are the estimated individual
#' causal effects (computed by comparing the observed data with the ML predictions).
#' Our estimand of interest is the average of the individual effects, so at each bootstrap
#' iteration we average the individual effects, obtaining a bootstrap distribution for the ATE
#' (which is in fact a CATE as we do that in each terminal node, i.e., conditionally on covariates).
#'
#' @param effect Numeric vector of estimated individual causal effects.
#' @param cate Object of class \code{rpart}, the estimated regression-tree-based CATE.
#' @param nboot Number of bootstrap replications.
#'
#' @return A matrix containing the following information: estimated CATE within
#' each node, estimated variance and confidence interval (upper and lower bound)
#' estimated by bootstrap. Each column corresponds to a terminal node of the tree.

boot_cate <- function(effect, cate, nboot, alpha){

  ### Param checks
  if(!is.numeric(effect)) stop("effect must be a numeric vector")
  if(class(cate) != "rpart") stop ("cate must be an 'rpart' object")
  if(nboot < 1 | all(!class(nboot) %in% c("numeric", "integer")) | nboot%%1 != 0) stop("nboot must be an integer greater than 1")
  if(alpha < 0 | alpha > 1) stop("Invalid confidence interval level, alpha must be positive and less than 1")
  
  ### Bootstrapping
  terminal.nodes <- cate$where
  x <- unique(terminal.nodes)
  node.inf <- mapply(x, FUN = function(x){y <- effect[which(terminal.nodes == x)];
  boot.dist <- matrix(sample(y, size = nboot*length(y), replace = TRUE),
                      nrow = nboot, ncol = length(y));
  mean.cate <- rowMeans(boot.dist);
  var.cate <- var(mean.cate);
  conf.cate <- quantile(mean.cate, probs = c(alpha/2, 1 - alpha/2));
  c(cate = mean(y), var.cate = var.cate, cate.lower = conf.cate[1], cate.upper = conf.cate[2])},
  SIMPLIFY = TRUE)
  colnames(node.inf) <- paste0("Node_", x)
  return(node.inf)

}


#' ATE estimation
#'
#' Internal function, used within the MLCM and bootstrap routines for the estimation of ATE
#'
#'
#' @param data A 'PanelMLCM' object from a previous call to \code{as.PanelMLCM}.
#' @param int_date The date of the intervention, treatment, policy introduction or shock.
#' @param best Object of class \code{train}, the best-performing ML method as selected
#'             by panel cross validation.
#' @param metric Character, the performance metric that should be used to select the optimal model.
#' @param ran.err Logical, whether to include a random error to the predicted/counterfactual
#'                post-intervention observations. It is set to \code{FALSE} when the objective is ATE
#'                estimation. It is set to \code{TRUE} when the objective is estimating bootstrap standard errors.
#'
#' @return A list with the following components:
#' \itemize{
#' \item ind_effects: matrix of estimated unit-level causal effects
#' \item ate: vector of estimated ATEs for each post-intervention period
#' }
#'

ate_est <- function(data, int_date, best, metric, ran.err, y.lag){

  ### Step 1. Settings (empty matrix)
  postimes <- data[which(data[, "Time"] >= int_date), "Time"]
  ind_effects <- matrix(NA, nrow = nrow(data[data$Time == int_date, ]) , ncol = length(unique(postimes)))
  colnames(ind_effects) <- unique(postimes)

  ### Step 2. Fit the best (optimized) ML algorithm on all pre-intervention data and make predictions
  ###         The following loops over the post-intervention periods and implements the recursive procedure
  ###         described in the paper
  for(i in 1:length(unique(postimes))){

    pre <- which(data[, "Time"] < postimes[i])
    post <- which(data[, "Time"] == postimes[i])
    invisible(capture.output(
      fit <- train(Y ~ .,
                   data = data[pre, !(names(data) %in% c("ID", "Time"))],
                   method = best$method,
                   metric = metric,
                   trControl = trainControl(method="none"),
                   tuneGrid = best$bestTune)
    ))

    ### Step 3. Counterfactual prediction, if the option 'ran.err' is active, a random error is added
    ###         to the prediction (recommended only during bootstrap to get reliable estimates of ATEs variance)
    if(ran.err){
      
      eps <- data[pre, "Y"] - predict.train(fit)
      error <- rnorm(n = nrow(data[post,]), mean = mean(eps), sd = sd(eps))
      pred <- predict.train(fit, newdata = data[post, ]) + error

    } else {

      pred <- predict.train(fit, newdata = data[post, ])
      error <- 0

    }

    ### STEP 4. ATE estimation (observed - predicted). Note that when there is more than 1 post-intervention
    ###         period and y.lag > 1, the MLCM routine will use the observed impacted series, disrupting all estimates.
    ###         e.g., int_date = 2020, 2 post-int periods, 2 lags: to predict Y_2020 MLCM will use Y_2018 (pre-int) and Y_2019 (pre-int),
    ###         but to predict Y_2021 MLCM will use Y_2019 (pre-int) and Y_2020 (post-int), which is not ok. With this last step,
    ###         we impute post-intervention Y's with their predicted counterfactual
    obs <- data[post, "Y"]
    ind_effects[,i] <- obs - pred

    if(length(unique(postimes)) > 1 & y.lag > 0 & i < length(unique(postimes))){

      # Substituting counterfactual Y (contemporaneous)
      data[post, "Y"] <- pred - error
      # Substituting counterfactual Y in future lags
      minl <- min(y.lag, length(unique(postimes))-i)

      for(l  in 1:minl){

        data[(post+l), paste0("Ylag",l)] <- pred - error
        data

      }
    }
  }
   
  ### Step 3. Returning the matrix of individual effects and the ATE
  ind_effects <- cbind(ID = unique(data$ID), ind_effects)
  ind_effects <- ind_effects[order(ind_effects[, "ID"], decreasing = F), ]
  return(list(ind_effects = ind_effects, ate = colMeans(as.matrix(ind_effects[, -1]))))
}

#' CATE estimation
#'
#' @param data A 'PanelMLCM' object from a previous call to \code{as.PanelMLCM}.
#' @param int_date The date of the intervention, treatment, policy introduction or shock.
#' @param ind_effects A matrix of estimated individual causal effects, returned from a previous
#'                    call to \code{ate_est}.
#' @param x.cate Optional, a matrix or data.frame of external regressors to use for CATE estimation.
#' @param nboot Number of bootstrap iterations.
#' @param alpha Confidence interval level to report for the ATE. Defaulting to 0.05 for a two sided
#'              95\% confidence interval.
#'
#' @return A list with the following components:
#' \itemize{
#' \item cate: a list with as many components as the post-intervention period,
#'       each containing an 'rpart' object.
#' \item cate.inf: a list with as many components as the post-intervention period,
#'       each containing the estimated CATE, its variance and confidence interval
#'       for the terminal nodes.
#' }
#'

cate_est <- function(data, int_date, ind_effects, x.cate, nboot, alpha){
  
  ### Step 1. Selecting post-intervention times
  post <- which(data$Time >= int_date)
  postimes <- data$Time[post]

  ### Step 2. Matrix containing the estimated individual effects and post-intervention covariates
  if(is.null(x.cate)){

    data_cate <- data.frame(Time = postimes, effect = c(t(ind_effects[,-1])), data[post, !names(data) %in% c("Y","Time","ID", "Ylag1")])

  } else {

    data_cate <- data.frame(Time = postimes, ID = data[post, "ID"], effect = c(t(ind_effects[,-1])))
    data_cate <- merge(data_cate, x.cate, by = c("ID", "Time"))
    data_cate <- data_cate[order(data_cate[, "ID"], decreasing = FALSE),]
    data_cate$ID <- NULL

  }

  ### Step 3. CATE estimation & inference
  cate <- lapply(unique(postimes), FUN = function(x){
    rpart(effect ~ ., method="anova", data = data_cate[data_cate$Time == x, -1], cp = 0, minbucket = 0.1*length(unique(data$ID)))})
  mat <- data.frame(postimes, c(t(ind_effects[,-1])))
  cate.inf <- mapply(x = cate, y = unique(postimes), FUN = function(x,y)(
    boot_cate(effect = mat[mat$postimes == y, -1], cate = x, nboot = nboot, alpha = alpha)), SIMPLIFY = FALSE)
  names(cate.inf) <- unique(postimes)

  ### Step 4. Returning estimated CATE
  return(list(cate = cate, cate.inf = cate.inf))
}


#' Checking CATE
#'
#' Internal function, used when external regressors are included in the estimation of CATE.
#' See Details in MLCM function. The function is purely used to checks the concordance of
#' the information included in 'data' and 'x.cate' (e.g., both datasets should contain
#' the same unique identifiers).
#'
#' @param x.cate Matrix or data.frame of external regressors used for CATE estimation
#' @param data Matrix, data.frame or PanelMLCM object
#' @param id Character, variable in 'data' containing unique identifiers
#' @param timevar Character, variable in 'data' containing times
#'

check_xcate <- function(x.cate, data, id, timevar){

  if(!(is.matrix(x.cate)|is.data.frame(x.cate))) stop("x.var must be 'matrix' or 'data.frame'")
  x.cate <- as.data.frame(x.cate)

  if(is.null(id)){ # later, change with is.PanelMLCM

    ind <- which(colnames(data) == "ID")
    ti <- which(colnames(data) == "Time")
    if(!colnames(data)[ind] %in% colnames(x.cate)) stop("'x.cate' must have a column named 'ID' with unique identifiers, like the one in 'data'")
    if(!colnames(data)[ti] %in% colnames(x.cate)) stop("'x.cate' must have a column named 'Time' with time identifiers, like the one in 'data'")
    if(!all.equal(unique(data[, "ID"]), unique(x.cate[, "ID"]))) stop ("unique identifiers differ for 'x.cate' and 'data'")

  } else {

    if(!id %in% colnames(x.cate)) stop("'x.cate' does not have unique identifiers or the colnames of identifiers do not match those in 'data'")
    if(!timevar %in% colnames(x.cate)) stop("'x.cate' does not have time identifiers or the colnames do not match those in 'data'")
    if(!all.equal(unique(data[, id]),unique(x.cate[, id]))) stop ("unique identifiers differ for 'x.cate' and 'data'")
    colnames(x.cate)[which(colnames(x.cate) == paste(id))] <- "ID"
    colnames(x.cate)[which(colnames(x.cate) == paste(timevar))] <- "Time"
  }

  return(x.cate)
}
