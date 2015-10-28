function generateGnuplotDataExtended(gnuplotFile, exp_results, exp_cmaes_results, maxfunevals)
  fid = fopen(gnuplotFile, 'w');
  [mBestf, q1Bestf, q3Bestf] = statisticsFromYEvals(exp_results.y_evals, maxfunevals, 1);

  % Additional columns, if they exist in y_evals
  if (size(exp_results.y_evals,2) >= 4)
    [mRMSE, q1RMSE, q3RMSE] = statisticsFromYEvals(exp_results.y_evals, maxfunevals, 3);
    [mCorr, q1Corr, q3Corr] = statisticsFromYEvals(exp_results.y_evals, maxfunevals, 4);
  end

  [mCmaes, q1Cmaes, q3Cmaes] = statisticsFromYEvals(exp_cmaes_results.y_evals, maxfunevals, 1);

  fprintf(fid, '# evals DataMedian DataQ1 DataQ3 CmaesMedian CmaesQ1 CmaesQ3 ModelRMSE ModelCorr\n');
  for i = 1:maxfunevals
    if (size(exp_results.y_evals,2) >= 4)
      fprintf(fid, '%d %e %e %e %e %e %e %e %e\n', i, mBestf(i), q1Bestf(i), q3Bestf(i), mCmaes(i), q1Cmaes(i), q3Cmaes(i), mRMSE(i), mCorr(i));
    else
      fprintf(fid, '%d %e %e %e %e %e %e\n', i, mBestf(i), q1Bestf(i), q3Bestf(i), mCmaes(i), q1Cmaes(i), q3Cmaes(i));
    end
  end

  fclose(fid);
end

