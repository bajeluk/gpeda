function [xopt varargout] = gpeda(options, eval_fcn, doe, sampler, rescale, restart, stop, varargin)
% Gausian Process based variation of estimation of distribution algorithm (EDA). Performs a
% heuristic optimization run.
%
% options - struct with the following fields:
%           popSize    - population size for each iteration
%           lowerBound - lower bound of the search (piece-wise)
%           upperBound - upper bound of the search
%           model      - custom model (see modelInit)
%           eval_fcn   - evaluation strategy options
%           doe        - initial design of experiment
%           sampler    - sampling strategy options
%           stop       - stop conditions options
% eval_fcn - evaluation strategy (function handle)
% doe     - initial design of experiment (function handle)
% sampler - sampling strategy (function handle or cell array of function handles)
% restart - restart conditions (function handle or cell array of function handles), e.g. stall
% stop    - termination conditions (function handle or cell array of function handles), e.g. 
%   evaluation budget depleted
% 
% As an optional argument you can pass in a function handle that will be called in each iteration with
% the current state of the run. You can use this to observe and debug the run.
%
% Some of the strategies (sampling, restart & stop conditions) can have composite structure: multiple
% function handles in a cell array. In that case they are used together (reduced with set union for
% sampling and logical or for stop/restart conditions). Respective field in the options struct should 
% also be cell arrays containing individual options structs for each part of the composite strategy.
%
% Return values can be:
% [xopt    ] = gpeda(...)
% [xopt run] = gpeda(...)
% where:
% xopt - the optimal input found
% run  - struct containing various statistics about the whole optimization run, including the dataset,
%   individual populations and predictions

warning('off', 'GP:InferenceFailed');

maxTrainErrors = 20;
% FIXME: add it to options!

lb = options.lowerBound(:)';
ub = options.upperBound(:)';
dim = length(lb);

run.options = options;

run.attempt = 1;
run.attempts = {};
run.notSPDCovarianceErrors = [];

att = 1;
run.attempts{att} = initAttempt(lb, ub, eval_fcn, doe, options);
pop = [];

fprintf('\n ==== Starting new optimization run ==== \n');
doRestart = 0; doRescale = 0;

while ~evalconds(stop, run, options.stop) % until one of the stop conditions occurs
  att = run.attempt;
  it = run.attempts{att}.iterations;
  ds = run.attempts{att}.dataset;
  M = run.attempts{att}.model;
  pop = []; tolXDistRatio = 0;

  fprintf('\n-- Attempt %d, iteration %d --\n', att, it);

  % train model
  disp('Training model...'  );
  [M_try nTrainErrors] = modelTrain(M, ds.x, ds.y, options);
  run.notSPDCovarianceErrors(end+1) = nTrainErrors;

  maxLogPdf = 0;    % to be set in case sampling crashes

  if (nTrainErrors > maxTrainErrors) 
    disp('Too many errors while training model. Find and evaluate minimum of the GP model.');
    if (~isfield(run.attempts{att}.model, 'dataset'))
      % the actual model does not have any dataset yet, take the very last model
      M = M_try;
    end

    [best_x_model best_y_model] = findModelMinimum(M, run.attempts{att}, dim);
    pop = best_x_model;
    % TODO: generate several solutions, not just one

    [doRestart, doRescale] = checkNumberOfSPDCovarianceErrors(run.notSPDCovarianceErrors, maxTrainErrors);
  else
    % sample new population
    M = M_try;
    run.attempts{att}.model = M;
    disp(['Sampling population ' int2str(it) '...']);
    try
      [pop tolXDistRatio maxLogPdf] = sample(sampler, M, dim, options.popSize, run.attempts{att}, options.sampler);
      disp(['  DEBUG: maxPdf = ' num2str(exp(maxLogPdf))]);
      % find continuous minimum of the GP and add it or replace the nearest 
      % individual if covariance matrix is still SPD
      [best_x_model] = findModelMinimum(M, run.attempts{att}, dim);
      if (isCovarianceSPD(M, [pop; best_x_model], 'bool'))
        disp('Augmenting dataset with model''s continuous minimum.');
        if (size(pop,1) == options.popSize)
          [minx mini] = min(distToDataset(best_x_model, pop));
          new_pop_i = [1:(mini-1) (mini+1):size(pop,1)];
          pop = [pop(new_pop_i,:); best_x_model];
        else
          pop = [pop; best_x_model];
        end
      end

    catch err
      [doRestart, doRescale] = dispatchSampleError(err, tolXDistRatio, doRestart, doRescale, size(pop));
      
      [best_x_model best_y_model exflag] = findModelMinimum(M, run.attempts{att}, dim);
      disp(['Continuous model minimum: f(' num2str(best_x_model) ') = ' ...
        num2str(best_y_model) ', exflag = ' num2str(exflag)]);
      pop = best_x_model;
      % TODO: generate several solutions, not just one
    end
  end

  % if there are at least some individuals returned from sampler(s)
  % or continous model minsearch
  if (exist('pop', 'var') && ~isempty(pop))

    run.attempts{att}.populations{it} = pop;
    run.attempts{att}.popSize(it) = size(pop, 1);
    run.attempts{att}.tolXDistRatios(it) = tolXDistRatio;
    run.attempts{att}.model = M;
    run.attempts{att}.maxLogPdf = maxLogPdf;

    % call the "observer", if there were any
    if nargin > 7 && isa(varargin{1}, 'function_handle')
      feval(varargin{1}, run);
    end

    % evaluate and add to dataset
    disp(['Evaluating ' num2str(size(pop, 1)) ' new individuals']);
    [m s2] = modelPredict(M, pop);
    x = transform(pop, run.attempts{att}.scale, run.attempts{att}.shift);
    y = feval(eval_fcn, x, m, s2, options.eval);

    % update statistics of the number of original evaluations and store the bests
    run.attempts{att} = updateAttempt(run.attempts{att}, pop, y, m, s2);

    % add new samples to the dataset for next iteration
    disp('Augmenting dataset');
    run.attempts{att}.dataset.x = [ds.x; pop];
    run.attempts{att}.dataset.y = [ds.y; y];

    % and we've completed an iteration
    run.attempts{att}.iterations = run.attempts{att}.iterations + 1;

  else
    disp('Warning: pop is empty!');
  end   % if (exist('pop') && ~isempty(pop))

  % if one of the restart conditions occurs
  if doRestart || (isfield(options, 'restart') && evalconds(restart, run, options.restart))
    disp('Restart conditions met, starting over...');

    run.attempt = run.attempt + 1;
    att = run.attempt;
  
    % initialize new attempt
    run.attempts{att} = initAttempt(lb, ub, eval_fcn, doe, options);
    run.notSPDCovarianceErrors = [];
    doRestart = 0;

    % free the not-needed memory for RESTART
    rmfield(run.attempts{att-1}, 'dataset');
    rmfield(run.attempts{att-1}, 'model');
    rmfield(run.attempts{att-1}, 'populations');

  elseif doRescale || isfield(options, 'rescale') && evalconds(rescale, run, options.rescale)
    [nlb nub] = computeRescaleLimits(run.attempts{att}, dim);

    if (min(abs([nlb nub])) > .8)
      % cancel rescale, we have new limits [-1 -1 ... -1] / [1 1 ... 1]
      disp('Rescaling conditions DID NOT met, limits [-1..-1] / [1..1]'); 
      % disp('Do restart. There is something wrong in the dataset.'); 
      % doRestart = 1;
    elseif (run.attempts{att}.iterations > 1)
      disp('Rescaling conditions met, zooming in...');

      run.attempts{att}.rescaleFlag = 1;
      run.attempt = run.attempt + 1;
      att = run.attempt;

      run.attempts{att} = initRescaleAttempt(run.attempts{att-1}, nlb, nub, options);
      disp('Got rescale attempt');

      % free the not-needed memory for RESCALE
      rmfield(run.attempts{att-1}, 'dataset');
      rmfield(run.attempts{att-1}, 'model');
      rmfield(run.attempts{att-1}, 'populations');
    else
      disp('Rescaling canceled, rescale was already in the last attempt.');
    end

    doRescale = 0;
  end
end

% return the best overall

besty = cell2mat(cellMap(run.attempts, @(attempt)( attempt.bests.yms2(end, 1) )));
bestx = cell2mat(cellMap(run.attempts, @(attempt)( attempt.bests.x(end, :)' )))';
scales = cell2mat(cellMap(run.attempts, @(attempt)( attempt.scale' )))';
shifts = cell2mat(cellMap(run.attempts, @(attempt)( attempt.shift' )))';

[yopt iopt] = min(besty)
xopt = transform(bestx(iopt,:), scales(iopt, :), shifts(iopt, :));
disp('Displaying bestx and besty of all the attempts:');

if nargout > 0
  varargout{1} = run;
end


end  % main function

% Support functions

function attempt = initAttempt(re_lb, re_ub, eval_fcn, doe_fcn, options)
  D = length(re_lb);

  if(isfield(options, 'model'))
    attempt.model = options.model;
  else
    attempt.model = modelInit(D);
  end

  attempt.iterations = 1;
  attempt.scale = (re_ub - re_lb) / (1 + 1);
  attempt.shift = -1 - (re_lb ./ attempt.scale);

  % generate initial dataset
  attempt.dataset.x = feval(doe_fcn, D, options.doe);

  dsx = attempt.dataset.x;
  dsx = transform(dsx, attempt.scale, attempt.shift);
  
  attempt.dataset.y = feval(eval_fcn, dsx, [], [], options.eval);
  attempt.evaluations = length(attempt.dataset.y);
  
  % FIXME assumes mean function is a constant
  ymean = mean(attempt.dataset.y);
  attempt.model.hyp.mean = ymean;

  attempt.populations = {};
  attempt.tolXDistRatios = [1];
  attempt.rescaleFlag = 0;

  [ym, im] = min(attempt.dataset.y);
  attempt.bests.x = attempt.dataset.x(im,:);    % a matrix with best input vectors rows 
  attempt.bests.yms2 = [ym 0 0]; % a matrix with rows [y m s2] for the best individual in each generation
  attempt.bests.evaluations = attempt.evaluations;
end

function attempt = initRescaleAttempt(lastAttempt, re_lb, re_ub, options)
  D = length(re_lb);

  if(isfield(options, 'model'))
    attempt.model = options.model;
  else
    hyp.mean = min(lastAttempt.dataset.y);
    attempt.model = modelInit(D, hyp);
  end

  lastScale = lastAttempt.scale;
  lastShift = lastAttempt.shift;

  attempt.iterations = 1;
  oub = transform(re_ub, lastScale, lastShift);
  olb = transform(re_lb, lastScale, lastShift);

  attempt.scale = (oub - olb) / 2;
  %attempt.shift = -(olb + oub) / 2;
  attempt.shift = -1 - (olb ./ attempt.scale);

  % generate initial dataset
  [fx fy] = filterDataset(lastAttempt.dataset, re_lb, re_ub);
  scaleDataset = (re_ub - re_lb) / (1 + 1);
  shiftDataset = -1 - (re_lb ./ scaleDataset);
  attempt.dataset.x = inv_transform(fx, scaleDataset, shiftDataset);
  attempt.dataset.y = fy;

  % FIXME assumes mean function is a constant
  ymean = mean(fy);
  attempt.model.hyp.mean = ymean;

  attempt.evaluations = 0;
  
  attempt.populations = {};
  attempt.tolXDistRatios = [1];

  [ym, im] = min(attempt.dataset.y);
  attempt.bests.x = attempt.dataset.x(im,:);    % a matrix with best input vectors rows 
  attempt.bests.yms2 = [ym 0 0]; % a matrix with rows [y m s2] for the best individual in each generation
  attempt.bests.evaluations = attempt.evaluations;
end

function tf = evalconds(conds, run, opts)
  if isa(conds, 'function_handle')
    tf = feval(conds, run, opts);
  else
    for k = 1:length(conds)
      conds{k} = feval(conds{k}, run, opts{k});
    end
    tf = cellReduce(conds, @(r, in) ( r || in ), 0);
  end
end

function [pop tol maxLogPdf] = sample(samplers, M, D, n, thisAttempt, opts)
  if isa(samplers, 'function_handle')
    [pop tol maxLogPdf] = feval(samplers, M, D, n, thisAttempt, opts);
  else
    % TODO: maxLogPdf!
    maxLogPdf = 0;
    for k = 1:length(samplers)
      [p t] = feval(samplers{k}, M, D, n, thisAttempt, opts{k});
      samplers{k} = [p t];
    end
    pop = cellReduce(samplers, @(r, in) ( [r; in] ), []);
    tol = cellReduce(samplers, @(r, in) ( min(r, in) ), 1);
  end
end

function [lb ub] = computeRescaleLimits(attempt, dim)
  dsx = attempt.dataset.x;
  dsxopt = repmat(attempt.bests.x(end, :), size(dsx, 1), 1);

  disp('Rescaling dataset fired, computing new limits.');

  % compute distances from the current optimum
  dist = sqrt(sum((dsxopt - dsx).^2, 2));
  [~, ind] = sort(dist);

  nNearestPoints = 15*dim;

  % take nNearestPoints closest points
  % TODO: make nNearestPoints a parameter
  if(length(ind) > nNearestPoints)
    besti = ind(1:nNearestPoints);
  else
    warning('Rescaling did not discard any points');
    besti = ind;
  end

  dsx = dsx(besti, :);

  % take extremes
  lb = min(dsx);
  ub = max(dsx);

  % extend the extremes
  dif = ub - lb;
  lb = lb - 0.05*dif;
  ub = ub + 0.05*dif;
  
  lb = max([lb; -1*ones(1, dim)]);
  ub = min([ub; 1*ones(1, dim)]);

  disp(['New bounds: ' num2str(lb) ' ' num2str(ub)]);
end

function [x y] = filterDataset(ds, lob, upb)
  alb = all(ds.x > repmat(lob, size(ds.x, 1), 1), 2);
  bub = all(ds.x < repmat(upb, size(ds.x, 1), 1), 2);

  ind = and(alb, bub);

  x = ds.x(ind, :);
  y = ds.y(ind, :);
end


function [pop fval exflag] = findModelMinimum(model, thisAttempt, dim)
  gp_predict = @(x_gp) modelPredict(model, x_gp);
  % % this is GADS Toolbox, which we dont have license for :(
  %{
  got_opts = optimset('Algorithm', 'interior-point');
  problem = createOptimProblem('fmincon', 'objective',...
    gp_predict,'x0',run.attempts{att}.bests.x(end,:),'lb',-1,'ub',1,'options',got_opts);
  gs = GlobalSearch;
  [minimum,fval] = run(gs, problem);
  %}

  % this is Matlab core fminsearch() implementation
  fminoptions = optimset('MaxFunEvals', min(1000*dim), ...
    'MaxIter', 200*dim, ...
    'Tolfun', 1e-10, ...
    'TolX', 1e-10, ...
    'Display', 'off');
  if (~isfield(thisAttempt.bests, 'x') || isempty(thisAttempt.bests.x))
    startx = 2 * rand(1, dim) - 1;
  else
    startx = thisAttempt.bests.x(end,:);
  end
  [pop fval exflag output] = fminsearch(gp_predict, startx, fminoptions);
  disp(['  fminsearch(): ' num2str(output.funcCount) ' evaluations.']);
end

function [doRestart, doRescale] = checkNumberOfSPDCovarianceErrors(notSPDCovarianceErrors, maxTrainErrors)
% checkes whether restart of rescale should happen according to SPD covarnace errors
% in this and privous run
  if (length(notSPDCovarianceErrors) > 1  &&  notSPDCovarianceErrors(end-1) > maxTrainErrors)
    % do restart, because last rescale didn't help
    disp('--> 2nd time! Restart.');
    doRestart = 1; doRescale = 0;
  else  % if (nTrainErrors > maxTrainErrors) 
    % first train error, do rescale
    disp('--> 1st time, do rescale and we will see.');
    doRescale = 1; doRestart = 0;
  end
end

function [doRestart, doRescale] = dispatchSampleError(err, tolXDistRatio, doRestart, doRescale, pop_size)
% indentifies different errors comming from sample()
% prints a warning message and decides whether rescale or restart should happen
  disp(['Sample error: ' err.identifier]);
  disp(getReport(err));
  if strcmp(err.identifier, 'sampleGibbs:NarrowDataset')
    doRestart = 1;
    fprintf('  NarrowDataset: size(pop) = %s; tolXDistRatio = %f\n', num2str(pop_size), tolXDistRatio);
  end
  if strcmp(err.identifier, 'sampleGibbs:CovarianceMatrixNotSPD')
    doRestart = 1; fprintf(err.message);
  end
  if strcmp(err.identifier, 'sampleGibbs:NarrowProbability')
    doRescale = 1;
    fprintf('  NarrowProbability: size(pop) = %s; tolXDistRatio = %f\n', num2str(pop_size), tolXDistRatio);
  end
  if strcmp(err.identifier, 'sampleGibbs:NoProbability')
    doRestart = 1;
    fprintf('  NoProbability. Restart.\n');
  end
end


function thisAttempt = updateAttempt(thisAttempt, pop_, y, m, s2)
% update statistics of the number of original evaluations

  thisAttempt.evaluations = thisAttempt.evaluations + length(y);
  thisAttempt.bests.evaluations = [thisAttempt.bests.evaluations; ...
    thisAttempt.evaluations];

  % store the best so far
  [ymin i] = min(y);
  if size(thisAttempt.bests.yms2, 1) < 1 || ymin < thisAttempt.bests.yms2(end, 1)
    % record improved solution
    ev = thisAttempt.evaluations;
    fprintf('Best solution improved to f(%s) = %s. (used %d evaluations in this attempt)\n', num2str(pop_(i,:)), num2str(ymin), ev);
    thisAttempt.bests.x(end + 1, :) = pop_(i, :);
    thisAttempt.bests.yms2(end + 1, :) = [y(i) m(i) s2(i)];
  else
    disp(['Best solution did not improve, still at ' num2str(thisAttempt.bests.yms2(end, :))]);
    % record unbeaten last solution
    thisAttempt.bests.x(end + 1, :) = thisAttempt.bests.x(end, :);
    thisAttempt.bests.yms2(end + 1, :) = thisAttempt.bests.yms2(end, :);
  end
end
