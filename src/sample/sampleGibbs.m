function [s tolXDistRatio neval] = sampleGibbs(M, dim, nsamples, attempt, spar)
% Gibbs MCMC sampler based on Probability of improvement
%
% M             GP model
% lb, ub        bounds within it should be sampled
% nsamples      the number of samples to be drawn
% spar.target   target value for computing probability of improvement

if (~isfield(spar, 'minTolX'))
  spar.minTolX = 0.002; % the minimum distance in X's to any point 
                        % in the dataset, lower produces numerical
                        % instability (not posit. definite covariance
                        % matrices in the GP model)
end

bestX = attempt.bests.x(end,:);
currBestY = attempt.bests.yms2(end,1);
currWorstY = min(attempt.dataset.y);
tolXDistRatio = 0;

% thresholds = [0 0.0001 0.001 (0.01 * (1:3:13)) 0.15 0.20 0.25 ...
%   0.30 0.50 1.0 2.0 3.0];
thresholds = [0 0.001 1.0];
% thresholds = [0 0.001 0.30 1.0 3.0];
% thresholds = flipdim(thresholds, 2);
targets = currBestY * (1 - thresholds .* (currWorstY - currBestY));

% check if covariance matrix is positive definite
lx = size(attempt.dataset.x,1);
spd = isCovarianceSPD(M, attempt.dataset.x);
if (spd < lx)
  exception = MException('sampleGibbs:CovarianceMatrixNotSPD', ...
              ['The matrix is not positive definite: p (from LL decomp) = ' num2str(lx - spd)]);
  tolXDistRatio = 1;
  throw(exception);
end

errCode = -1; i = 1;
s = [];
nTolXErrors = 0;
neval = 0;
while (errCode ~= 0 && i <= length(thresholds))
  density = @(xSpace) modelGetPOI(M, xSpace, targets(i));

  % % DEBUG
  % debugGridSize = 201;
  % [xyColumn xm ym] = grid2d(-1*ones(1,dim), ones(1,dim), debugGridSize);
  % poi = density(xyColumn);
  % % f = figure();
  % s1 = subplot(2,2,[1 3]);
  % [~, sf] = contour(xm, ym, reshape(poi, debugGridSize, debugGridSize));
  % colorbar();
  % s2(1) = subplot(2,2,2);
  % s2(2) = subplot(2,2,4);
  % debugArgs = {};
  % % /DEBUG
  
  % % try use fminsearch() to find a place with highest POI
  % % -- does not work well :(
  % fminoptions = optimset('MaxFunEvals', min(1e6*dim), ...
  %   'MaxIter', 1000*dim, ...
  %   'Tolfun', 1e-7, ...
  %   'TolX', 1e-7, ...
  %   'Display', 'off');
  % [maxPOIfmins, ~, exitflag] = fminsearch(@(x) -density(x), bestX, fminoptions);
  % fprintf('sampleGibbs(): Maximal POI found at (%s) with exitflag %d.\n', num2str(maxPOIfmins), exitflag);
  % startX = maxPOIfmins;

  % this is GADS Toolbox, which we dont have license for :(
  % max_density = @(xx) -density(xx);
  % got_opts = optimset('Algorithm', 'interior-point');
  % problem = createOptimProblem('fmincon', 'objective',...
  %   max_density,'x0',attempt.bests.x(end,:),...
  %   'lb',-1*ones(1,dim),'ub',ones(1,dim),'options',got_opts);
  % gs = GlobalSearch;
  % [startX,maxPOIY] = run(gs, problem);

  % ycond = @(y) (y>0);
  % maxPOIX = [];
  % [maxPOIX, maxPOIY] = getMax(density, dim, ycond);
  
  % % evaluate POI on a grid and access point with the highest POI
  % % TODO: try running sampler for each such a region, not just maxPOI
  % xyz = gridnd(-1*ones(1,dim), ones(1,dim), 20);
  % xyzPOI = density(xyz);
  % neval = neval + 1 + 0.01 * size(xyz,1);
  % [maxPOIY ind] = max(xyzPOI);
  % startX = xyz(ind,:);

  startX = bestX;

  % if (maxPOIY > 0)
  if (density(startX) > 0)
    [s_, neval_, errCode, nTolXErrors_] = gibbsSampler(density, dim, nsamples, startX, attempt.dataset.x, spar); % , debugArgs);
    neval = neval + neval_;

    if (size(s_,1) > size(s,1))
      s = s_;
      nTolXErros = nTolXErrors_;
    end
  else
    errCode = 1;
    disp('No points with non-zero POI to start at.');
  end
  % TODO: start the sampler in multiple local maxima of POI, not just one of them
  %       draft of such code is below
  % errCode = 1; nTolXErrors = 0;
  % pointsPOI = 1;
  % while (size(s, 1) < nsamples && pointsPOI <= size(maxPOIX,1))
  %   [newPop, errCode, nTolXErrors] = gibbsSampler(density, dim, nsamples, maxPOIX(pointsPOI,:), attempt.dataset.x, spar); % , debugArgs);
  %   s = [s; newPop];
  %   pointsPOI = pointsPOI + 1;
  % end

  switch (errCode)
  case 1
    disp(['sampleGibbs(): There is no probability of improvement with threshold ' num2str(thresholds(i))]);
  case 2
    disp(['sampleGibbs(): Could not sample enough individuals far enough between each other with threshold ' num2str(thresholds(i))]);
  end
  i = i + 1;
end

if (nTolXErrors > 0)
  disp(['sampleGibbs(): Note: sampling in narrow region: nTolXErrors == ' num2str(nTolXErrors)]);
  tolXDistRatio = nTolXErrors/nsamples;
else
  tolXDistRatio = 0;
end

if (isempty(s))
  switch (errCode)
  case 1
    exception = MException('sampleGibbs:NoProbability', 'There is no probability of improvement.');
    throw(exception);
  case 2
    exception = MException('sampleGibbs:NarrowProbability', 'Could not sample enough individuals far enough between each other.');
    throw(exception);
  otherwise
    exception = MException('sampleGibbs:EmptyPopulation', 'Population is empty.');
    throw(exception);
  end
end

function [s, neval, errCode, nTolXErrors] = gibbsSampler(density, dim, nsamples, startX, dataset, spar, debugArgs)
% Gibbs MCMC sampler itself
%
% M             GP model
% lb, ub        bounds within it should be sampled
% nsamples      the number of samples to be drawn
% spar.target   target value for computing probability of improvement

% Parameters
thin = dim * 5;        % the number of discarted samples between actual draws
gridSize = 400;         % the number of samples of POI from which the 
                        % marginal's inverse CDF is estimated
nSamplePOITries = 5;    % how many times the POI is sampled, each time
                        % with double dense grid (the *gridSize*
                        % is doubled each try)
minSampledPoints = 8;   % the minimum number of points to get
                        % good-shaped probability and so not doubling 
                        % density of the grid
maxTolXErrors = 2 * nsamples;   % the maximum number of tries of new
                                % sampling (altogether) when new X's 
                                % are closer than *minTolX* 
                                % from other data in the dataset
difx = 2;               % length of the bounding box of X's

% Prior Values -- take the suggested value were, hopefully, is non-zero POI
x = startX;
% OLD: 
% generate all the variables from Normal distribution
% centered along current best point
% x = startX .* (difx/8 .* randn(1,dim));

%Allocate Space to Save Gibbs Sampling Draws
s = zeros(nsamples,dim);
errCode = 0;
highestPOI = -Inf;
highestPOIX = zeros(1,dim);

% Run the Gibbs Sampler...
% ... for the specified number of draws
% - leave one sample for the biggest PoI found by this run
nSampled = 0;
nTolXErrors = 0;
neval = 0;
while ((nSampled < nsamples) && (nTolXErrors < maxTolXErrors))
  for j = 1:thin
    % take the variables in random order
    for k = 1:dim % randperm(dim)
      % Estimate inverse CDF of the chosen marginal
      % at (x_1,...,x_(k-1), X, x_(k+1),...,x_(dim))
      
      % sample the probability of improvement (POI)
      % if less than *minSampledPoints* with non zero probability 
      % is returned, give it *nSamplePOITries* tries doubling the number 
      % of sampled points each time
      nPoints = 0; tryNo = 1; sampleSize = gridSize;
      while ((nPoints < minSampledPoints) && (tryNo <= nSamplePOITries))
        xGrid = linspace(-1, 1, sampleSize)';
        xSpace = repmat(x,length(xGrid),1);
        xSpace(:,k) = xGrid;
        poi_density = density(xSpace);
        % this +1 instead of +size(xSpace,1) is due to batch evaluation of density in gp() call
        neval = neval + 1 + 0.01*size(xSpace,1);
        empIntegral = sum(poi_density);
        
        % save maximal POI found so far
        [maxPOI, mpi] = max(poi_density);
        if (maxPOI > highestPOI)
          highestPOI = maxPOI; highestPOIX = xSpace(mpi,:);
        end

        nonzeroProb = (poi_density./empIntegral > eps);
        nPoints = sum(nonzeroProb);
        sampleSize = 2 * sampleSize;
        tryNo = tryNo + 1;
      end

      xGrid = xGrid(nonzeroProb,:);
      poi_density = poi_density(nonzeroProb);
      
      if (nPoints == 0)
        % warning('sampleGibbs(): There is no probability of improvement. Giving up.');
        errCode = 1;
        s((nSampled+1):end,:) = [];
        return
      end
      if (nPoints == 1)
        warning('sampleGibbs(): There is practically zero probability of improvement. Numerical instability possible.');
        F = [0; 0.5; 1];
        kernel_width = 0.005 * difx;
        xGrid = xGrid + kernel_width * [-1 0 1];
      else
        if (nPoints < minSampledPoints)
          % warning('sampleGibbs(): The probability of improvement is very local. Numerical instability possible.')
        end
        F_step = cumsum(poi_density);             % empirical step-like cumsum; last item = integral
        F_step = F_step ./ F_step(end);           % calculate empirical CDF by dividing by the integral
        F_step = F_step(:);
        F = ([0; F_step(1:end-1)] + F_step)/2;    % midpoints CDF
        % augment the midpoints CDF on bounds to start at 0 and end at 1
        %   copy slope of this parts from the first/last part of the midpoint CDF
        optOut = (F < sqrt(eps)) | (F > (1 - sqrt(eps)));
        F(optOut) = [];
        xGrid(optOut) = [];
        if (length(xGrid) > 1)
          xGrid = [xGrid(1) - F(1)*(xGrid(2)-xGrid(1))/(F(2)-F(1)); ...
            xGrid; ...
            xGrid(end) + (1-F(end))*(xGrid(end)-xGrid(end-1))/(F(end)-F(end-1))];
          F = [0; F; 1];
        else
          % warning('sampleGibbs(): There is no probability of improvement. Giving up.');
          errCode = 1;
          s((nSampled+1):end,:) = [];
          return
        end
      end
      
      % draw a sample from the estimated marginal 1D distribution
      % - sample the uniform U[0,1] and put this value into the inverse CDF
      % - inverse CDF is taken as linear interpolation of inverted 
      %   empirical CDF
      new_x = interp1(F, xGrid, rand(), 'linear', 'extrap');
      % replace the current covariate by this sampled value
      x(k) = new_x;

      % DEBUG
      % plot(debugArgs{2}(k), xSpace(nonzeroProb,k), poi_density, 'g-');
      % margins = [x' x'];
      % margins(k,:) = [lb(k) ub(k)];
      % hold(debugArgs{1},'on');
      % plot(debugArgs{1}, margins(1,:), margins(2,:), 'g-');
      % hold(debugArgs{1},'off');
      % /DEBUG
    end
    % DEBUG
    % hold(debugArgs{1},'on');
    % plot(debugArgs{1}, x(1), x(2), 'r+');
    % hold(debugArgs{1},'off');
    % /DEBUG
  end

  % Check the TolX condition:
  dataset_s = [dataset; s(1:nSampled,:)];
  min_d = min(distToDataset(x, dataset_s));
  if ((min_d >= spar.minTolX) && isCovarianceSPD(M, dataset_s, 'bool'))
    nSampled = nSampled + 1;
    s(nSampled,:) = x;
  else
    nTolXErrors = nTolXErrors + 1;
  end
  % DEBUG
  % hold(debugArgs{1},'on');
  % plot(debugArgs{1}, x(1), x(2), 'b*');
  % hold(debugArgs{1},'off');
  % /DEBUG
end

% if (highestPOI > -Inf)
%   % save the best POI found as the last individual in the population
%   s(nsamples,:) = highestPOIX;
% else
%   % it should be returned from this subfunction earlier!
%   error('sampleGibbs:NoProbability', 'There is no probability of improvement. THE PROGRAM SHOULD NOT COME HERE!');
% end

if (nSampled < (nsamples));
  s((nSampled+1):end,:) = [];
  % warning('sampleGibbs:NarrowProbability', ...
  %   ['Not enough (only ' num2str(nSampled) ' out of ' num2str(nsamples) ...
  %    ') draws can be sampled far enough from the dataset.']);
  disp(['sampleGibbs(): Not enough (only ' num2str(nSampled) ' out of ' num2str(nsamples) ...
     ') draws can be sampled far enough from the dataset.']);
  errCode = 2;
  return;
end

end % subfunction gibbsSampler()


function [maxPOIX, maxPOIY] = getMax(f, dim, ycond)
  % evaluate function on a grid and start a fminsearch() from such a point
  % to find local maxima of the input function
  gridN = 5;
  maxPOIY = []; maxPOIX = [];

  xyz = gridnd(-1*ones(1,dim), ones(1,dim), gridN);
  for grid_i = 1:size(xyz,1)
    % % for each point in the grid, try fminsearch()
    [maxX, maxY] = fminsearch(f, xyz(grid_i,:));
    % check condition on Y value
    if (ycond(maxY))
      if (~isempty(maxPOIY))
        ds = min(distToDataset(maxX, maxPOIX));
      else
        ds = 1;
      end
      if (ds > sqrt(eps))
        maxPOIX = [maxPOIX; maxX];
        maxPOIY = [maxPOIY;  maxY];
      end
    end
  end
end

end % function
