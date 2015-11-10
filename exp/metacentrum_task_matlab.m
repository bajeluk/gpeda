function metacentrum_task_matlab(exp_id, exppath_short, id, varargin)

  % NFS file for logging results
  USE_FILELOG = 0;
  LOGFILENAME='log.txt';
  DEFAULTLOGFILE = '/storage/plzen1/home/bajeluk/public/log.txt';

  % FTP connection for logging results, NFS file log is needed for FTP!
  USE_FTPLOG = 0  &&  USE_FILELOG;
  FTP_HOSTNAME='optim.wz.cz';
  FTP_USERNAME='optim.wz.cz';
  FTP_PASS='metacentrum';

  % setting up paths
  OUTPUTDIR = getenv('SCRATCHDIR');     % empty/'' if $SCRATCHDIR var does not exist

  % rename queued_file to computing_file
  queuedFile = [exppath_short filesep exp_id filesep 'queued_' num2str(id)];
  calculatingFile = [exppath_short filesep exp_id filesep 'calculating_' num2str(id)];
  if (exist(queuedFile, 'file'))
    movefile(queuedFile, calculatingFile);
  end

  % parameters of the current job
  if (ischar(id)) id = str2num(id); end
  load([exppath_short filesep exp_id '/params.mat'], 'bbParamDef', 'sgParamDef', 'cmParamDef');
  [bbParams, sgParams] = getParamsFromIndex(id, bbParamDef, sgParamDef, cmParamDef);
  fun = bbParams.functions(end);
  dim = bbParams.dimensions(end);
  if (isfield(sgParams, 'modelType'))
    model = sgParams.modelType;
  else
    model = 'NONE';
  end
  metaOpts.nInstances = length(bbParams.instances);

  % obsolete:
  % convert from string to integer (if supplied on commandline)
  % if (ischar(fun)) fun = str2num(fun); end
  % if (ischar(dim)) dim = str2num(dim); end
  % if (ischar(id)) id = str2num(id); end

  % setting up paths (contd.)
  EXPPATH = [exppath_short filesep exp_id];
  RESULTSFILE = [EXPPATH '/' exp_id '_results_' num2str(fun) '_' num2str(dim) 'D_' num2str(id) '.mat'];
  % this could be changed to [OUTPUTDIR '/' ...] (or SCRATCHDIR):
  FILESTDOUT = [EXPPATH '/' exp_id '__log__' num2str(id) '.txt'];

  % # relict from shell script
  % FILEMANAGER="${EXPPATH}/${EXPID}_manager.sh"
  % MATLABCALL="matlab"
  % MATLABPARAMS="-singleCompThread -nodisplay -nodesktop"
  % MACHINE=`head -1 $PBS_NODEFILE`

  % metaOpts -- structure with info about current Task and Metacentrum environ. variables
  if (nargin >= 4)
    metaOpts = varargin{1};
  else
    metaOpts.model = model;
    metaOpts.logdir = '';
    metaOpts.machine = '';
  end
  nodeFile = fopen(getenv('PBS_NODEFILE'), 'r');
  if (nodeFile > 0)
    metaOpts.machine = fgetl(nodeFile);
    fclose(nodeFile);
  end
  if (USE_FILELOG)
    if (~ isfield(metaOpts, 'logdir') || isempty(metaOpts.logdir))
      LOGFILE = DEFAULTLOGFILE;
      metaOpts.logdir = '/storage/plzen1/home/bajeluk/public/';
    else
      LOGFILE = [metaOpts.logdir filesep LOGFILENAME];
    end
  end

  % # relict from shell script
  % # clean up the lock-file
  % trap "rm -f $EXPPATH/queued_$ID" TERM EXIT

  cd([exppath_short filesep '..' filesep '..']);
  startup;

  % STDOUT logging
  if (~isempty(FILESTDOUT))
    fout = fopen(FILESTDOUT, 'a');
    fprintf(fout, '###########################################\n');
    fprintf(fout, '     Matlab call id=%d\n\n', id);
    fprintf(fout, '  dim(s): %d    f(s): %d    N(inst): %d\n', dim, fun, metaOpts.nInstances);
    fprintf(fout, '  model: %s\n', metaOpts.model);
    fprintf(fout, '###########################################\n');
    fclose(fout);
    % TODO: forward all the text output into a file, but it has to be on a local SCRATCH
  end

  % LOGFILE loggig start and success of each experiment ID into local/NFS file
  if (USE_FILELOG)
    flog = fopen(LOGFILE, 'a');
    datest = datestr(now,'yyyy-mm-dd HH:MM:ss');
    fprintf(flog, '%s  **%s** at [%s] %d started.\n', datest, exp_id, metaOpts.machine, id);
    fclose(flog);
  end

  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  % CORE COMPUTATION (begin)
  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

  bbob_test_01(id, exp_id, exppath_short, OUTPUTDIR);

  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  % CORE COMPUTATION (end)
  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


  datest = datestr(now,'yyyy-mm-dd HH:MM:ss');

  % STDOUT logging
  if (~isempty(FILESTDOUT))
    fout = fopen(FILESTDOUT, 'a');
    if (exist(RESULTSFILE, 'file'))
      fprintf(fout, '%s  **%s** at [%s] %d succeeded.\n', datest, exp_id, metaOpts.machine, id);
    else
      fprintf(fout, '%s  **%s** at [%s] %d !!!  FAILED  !!!\n', datest, exp_id, metaOpts.machine, id);
    end
    fclose(fout);
  end

  % LOGFILE loggig start and success of each experiment ID into local/NFS file
  if (USE_FILELOG)
    flog = fopen(LOGFILE, 'a');
    if (exist(RESULTSFILE, 'file'))
      % if [ "$3" -eq 0  -a  -f "$1"  -a  "$1" -nt "$FILEMANAGER" ]; then
      fprintf(flog, '%s  **%s** at [%s] %d succeeded.\n', datest, exp_id, metaOpts.machine, id);
    else
      fprintf(flog, '%s  **%s** at [%s] %d !!!  FAILED  !!!\n', datest, exp_id, metaOpts.machine, id);
      % # tail -n 60 "$FILESTDOUT" | mail -s "Metacentrum: chyba v uloze $PBS_JOBID $PBS_JOBNAME" $USER@arien.metacentrum.cz
    end
    fprintf(flog, '%s  **%s** at [%s] ==== FINISHED ====\n', datest, exp_id, metaOpts.machine);
    fclose(flog);
  end

  % copy to LOGFILE via FTP
  if (USE_FTPLOG)
    ftpstr = sprintf('ftp -n %s <<EOD\nuser %s %s\nlcd %s\nput %s\nbye\nEOD\n', FTP_HOSTNAME, FTP_USERNAME, FTP_PASS, metaOpts.logdir, LOGFILENAME);
    system(ftpstr);
  end

  % copy the BBOB results onto persistant storage if outside EXPPATH
  % ( should be done already in bbob_test_01() )
  if (~isempty(OUTPUTDIR) && ~strcmpi(OUTPUTDIR, EXPPATH))
    % copy the output to the final storage (if OUTPUTDIR and EXPPATH differs)
    system(['cp -pR ' OUTPUTDIR '/* ' EXPPATH '/']);
  end

end
