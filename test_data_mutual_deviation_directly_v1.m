function outputFiles = test_data_mutual_deviation_directly()
% TEST_DATA_MUTUAL_DEVIATION_DIRECTLY
% 通过弹窗选择A、B两地测量数据，以A为基准自动寻找连续24小时，
% 对A、B分别建立1秒时间网格并补齐，计算D=A-B，输出CSV和差分图。

    maximumInternalGapSeconds = 90;
    programFolder = fileparts(mfilename('fullpath'));
    projectFolder = fileparts(programFolder);
    dataFolder = fullfile(projectFolder, 'data');
    outputFiles = struct('resultCsv', "", 'figure', "");

    [aName, aPath] = uigetfile({'*.csv', 'CSV数据文件 (*.csv)'}, ...
        '请选择A站测量数据（被测点）', dataFolder);
    if isequal(aName, 0)
        fprintf('未选择A站文件，程序已结束。\n');
        return;
    end
    aFile = fullfile(aPath, aName);
    [bName, bPath] = uigetfile({'*.csv', 'CSV数据文件 (*.csv)'}, ...
        '请选择B站测量数据（测试点）', dataFolder);
    if isequal(bName, 0)
        fprintf('未选择B站文件，程序已结束。\n');
        return;
    end
    bFile = fullfile(bPath, bName);
    if ~isfile(aFile) || ~isfile(bFile)
        error('A或B输入文件不存在。');
    end

    aStation = readStationNameOnly(aFile, 'A站');
    bStation = readStationNameOnly(bFile, 'B站');
    stationAnswers = inputdlg({'A站名称（测试站点）：', 'B站名称（被测站点）：'}, ...
        '确认A、B站点身份', [1, 48], {char(aStation), char(bStation)});
    if isempty(stationAnswers)
        fprintf('未确认站点名称，程序已结束。\n');
        return;
    end
    aStation = strtrim(string(stationAnswers{1}));
    bStation = strtrim(string(stationAnswers{2}));
    if strlength(aStation) == 0, aStation = "A站"; end
    if strlength(bStation) == 0, bStation = "B站"; end
    while true
        windowAnswer = inputdlg({'窗口时长（小时）：'}, '设置窗口时长', ...
            [1, 44], {'24'});
        if isempty(windowAnswer)
            fprintf('未设置窗口时长，程序已结束。\n');
            return;
        end
        try
            [~, windowPointCount] = validateWindowHours(windowAnswer{1});
            break;
        catch validationError
            errordlg(validationError.message, '窗口时长无效', 'modal');
        end
    end
    [aTime, aValue, ~, aStats] = readMeasurementCsv(aFile, 'A站');
    [bTime, bValue, ~, bStats] = readMeasurementCsv(bFile, 'B站');

    fprintf('正在寻找连续24小时窗口……\n');
    [windowStart, windowEnd] = chooseWindowStart(aTime, bTime, windowPointCount, maximumInternalGapSeconds);
    gridTime = (windowStart:seconds(1):windowEnd - seconds(1)).';
    aGrid = regularizeSeries(aTime, aValue, gridTime, maximumInternalGapSeconds);
    bGrid = regularizeSeries(bTime, bValue, gridTime, maximumInternalGapSeconds);
    if any(~isfinite(aGrid)) || any(~isfinite(bGrid))
        error('A或B在选定24小时窗口内仍存在无法补齐的数据。');
    end

    meanA = mean(aGrid(1:300), 'omitnan');
    meanB = mean(bGrid(1:300), 'omitnan');
    aNew = aGrid - meanA;
    bNew = bGrid - meanB;
    differential = aNew - bNew;
    statistics = calculateStatistics(differential);
    previewFigure = createDifferentialFigure(gridTime, differential, ...
        aStation, bStation, statistics, '差分结果预览');
    drawnow;
    choice = questdlg('是否输出当前24小时差分结果？', '确认输出', ...
        '输出结果', '取消', '输出结果');
    if ~strcmp(choice, '输出结果')
        if isvalid(previewFigure), close(previewFigure); end
        fprintf('用户取消输出，程序已结束。\n');
        return;
    end

    safeA = makeSafeFileName(aStation);
    safeB = makeSafeFileName(bStation);
    [~, aBase, ~] = fileparts(aFile);
    dateText = regexp(aBase, '\\d{4}-\\d{2}-\\d{2}', 'match', 'once');
    if isempty(dateText), dateText = datestr(windowStart, 'yyyy-mm-dd'); end
    resultRoot = fullfile(projectFolder, 'result');
    baseFolderName = sprintf('%s差%s_%s', safeB, safeA, dateText);
    outputFolder = fullfile(resultRoot, baseFolderName);
    number = 2;
    while isfolder(outputFolder) || isfile(outputFolder)
        outputFolder = fullfile(resultRoot, sprintf('%s_%02d', baseFolderName, number));
        number = number + 1;
    end
    [created, message] = mkdir(outputFolder);
    if ~created, error('无法创建结果目录：%s', message); end
    copyInputDataFiles(outputFolder, aFile, bFile, aStation, bStation);

    gridTime.Format = 'yyyy-MM-dd HH:mm:ss';
    resultTable = table(gridTime, aGrid, bGrid, aNew, bNew, differential, ...
        'VariableNames', {'时间', 'A站测量值_ns', 'B站测量值_ns', ...
        'Anew_A减均值A_ns', 'Bnew_B减均值B_ns', '差分结果D_Anew减Bnew_ns'});
    outputFiles.resultCsv = string(fullfile(outputFolder, ...
        sprintf('%s站差分改正结果.csv', safeA)));
    writetable(resultTable, outputFiles.resultCsv, 'Delimiter', ',', 'Encoding', 'UTF-8');

    outputFiles.figure = string(fullfile(outputFolder, ...
        sprintf('%s差分改正效果.png', safeB)));
    finalFigure = createDifferentialFigure(gridTime, differential, ...
        aStation, bStation, statistics, sprintf('%s差分改正效果', char(bStation)));
    saveHighResolutionFigure(finalFigure, char(outputFiles.figure));
    if isvalid(previewFigure), close(previewFigure); end
    fprintf('输出完成：%s\n', outputFolder);
    fprintf('均值：%.2f ns；样本标准差：%.2f ns；绝对值95%%分位值：%.2f ns\n', ...
        statistics.mean, statistics.std, statistics.p95);
    fprintf('A读取%d条有效记录，B读取%d条有效记录。\n', ...
        aStats.validCount, bStats.validCount);
end

function [hoursValue, pointCount] = validateWindowHours(rawValue)
    numericValue = str2double(strtrim(string(rawValue)));
    if ~isscalar(numericValue) || ~isfinite(numericValue) || numericValue <= 0
        error('窗口时长必须是大于0的数值。');
    end
    rawPointCount = numericValue * 3600;
    pointCount = round(rawPointCount);
    tolerance = 32 * eps(max(1, abs(rawPointCount)));
    if abs(rawPointCount - pointCount) > tolerance
        error('窗口时长换算后必须是整数秒。');
    end
    if pointCount < 300
        error('窗口时长换算后必须至少包含300个1秒点。');
    end
    hoursValue = pointCount / 3600;
end

function copyInputDataFiles(outputFolder, aFile, bFile, aStation, bStation)
    aDate = extractFileDate(aFile);
    bDate = extractFileDate(bFile);
    copyfile(aFile, fullfile(outputFolder, sprintf('%s_测试站点数据_%s.csv', ...
        makeSafeFileName(aStation), aDate)));
    copyfile(bFile, fullfile(outputFolder, sprintf('%s_被测试站点数据_%s.csv', ...
        makeSafeFileName(bStation), bDate)));
end

function dateText = extractFileDate(inputFile)
    [~, baseName, ~] = fileparts(inputFile);
    dateText = regexp(baseName, '\\d{4}-\\d{2}-\\d{2}', 'match', 'once');
    if isempty(dateText), dateText = '未注明日期'; end
end

function [timeData, values, stationName, statistics] = readMeasurementCsv(inputFile, label)
    [source, encoding] = readSelectedCsv(inputFile, {'time', 'differentialDelay'}, {'stationName'}, label);
    timeData = parseTimeVector(string(source.time), label);
    values = double(source.differentialDelay);
    stationName = extractStationName(source, label);
    valid = ~isnat(timeData) & isfinite(values);
    statistics = struct('totalCount', height(source), 'validCount', sum(valid), ...
        'invalidCount', sum(~valid), 'encoding', string(encoding));
    if ~any(valid), error('%s没有有效的time和differentialDelay数据。', label); end
    timeData = timeData(valid); values = values(valid);
    [timeData, order] = sort(timeData); values = values(order);
    [timeData, index] = unique(timeData, 'last'); values = values(index);
end

function stationName = readStationNameOnly(inputFile, fallback)
    stationName = string(fallback);
    try
        opts = detectImportOptions(inputFile, 'FileType', 'text', 'Delimiter', ',', ...
            'VariableNamingRule', 'preserve');
        if ~ismember('stationName', opts.VariableNames), return; end
        opts.SelectedVariableNames = {'stationName'};
        opts = setvartype(opts, 'stationName', 'string');
        source = readtable(inputFile, opts);
        stationName = extractStationName(source, fallback);
    catch
        stationName = string(fallback);
    end
end

function [source, usedEncoding] = readSelectedCsv(inputFile, required, optional, label)
    encodings = {'UTF-8', 'GBK'}; lastError = '';
    for k = 1:numel(encodings)
        try
            opts = detectImportOptions(inputFile, 'FileType', 'text', 'Delimiter', ',', ...
                'Encoding', encodings{k}, 'VariableNamingRule', 'preserve');
            if ~all(ismember(required, opts.VariableNames))
                error('%s缺少字段time或differentialDelay。', label);
            end
            selected = required;
            for j = 1:numel(optional)
                if ismember(optional{j}, opts.VariableNames), selected{end+1} = optional{j}; end %#ok<AGROW>
            end
            opts.SelectedVariableNames = selected;
            opts = setvartype(opts, 'time', 'string');
            opts = setvartype(opts, 'differentialDelay', 'double');
            if ismember('stationName', selected), opts = setvartype(opts, 'stationName', 'string'); end
            source = readtable(inputFile, opts); usedEncoding = encodings{k}; return;
        catch ME
            lastError = ME.message;
        end
    end
    error('无法读取%s：%s', label, lastError);
end

function timeData = parseTimeVector(text, label)
    text = strtrim(string(text));
    timeData = NaT(numel(text), 1, 'Format', 'yyyy-MM-dd HH:mm:ss');
    formats = {'yyyy-MM-dd HH:mm:ss', 'MM/dd/yyyy HH:mm:ss'};
    for k = 1:numel(formats)
        pending = find(isnat(timeData) & strlength(text) > 0);
        if isempty(pending), break; end
        for j = reshape(pending, 1, [])
            try
                timeData(j) = datetime(text(j), 'InputFormat', formats{k}, ...
                    'Format', 'yyyy-MM-dd HH:mm:ss');
            catch
            end
        end
    end
    if all(isnat(timeData)), error('%s时间无法解析。', label); end
end

function name = extractStationName(source, fallback)
    name = string(fallback);
    if ismember('stationName', source.Properties.VariableNames)
        values = strtrim(string(source.stationName));
        index = find(~ismissing(values) & strlength(values) > 0, 1);
        if ~isempty(index), name = values(index); end
    end
end

function [startTime, endTime] = chooseWindowStart(aTime, bTime, pointCount, maximumGapSeconds)
    if isempty(aTime) || isempty(bTime)
        error('A或B数据中没有有效时间。');
    end
    candidates = aTime;
    for k = 1:numel(candidates)
        candidateStart = candidates(k);
        candidateEnd = candidateStart + seconds(pointCount - 1);
        gridTime = (candidateStart:seconds(1):candidateEnd).';
        aGrid = regularizeSeries(aTime, ones(size(aTime)), gridTime, maximumGapSeconds);
        bGrid = regularizeSeries(bTime, ones(size(bTime)), gridTime, maximumGapSeconds);
        if all(isfinite(aGrid)) && all(isfinite(bGrid))
            startTime = candidateStart;
            endTime = candidateStart + seconds(pointCount);
            return;
        end
    end
    error('找不到内部缺口不超过%d秒且可补齐的连续24小时窗口。', maximumGapSeconds);
end

function gridValues = regularizeSeries(timeData, values, gridTime, maximumGapSeconds)
    gridValues = nan(size(gridTime));
    [matched, index] = ismember(gridTime, timeData); gridValues(matched) = values(index(matched));
    missing = ~isfinite(gridValues);
    transitions = diff([false; missing; false]);
    starts = find(transitions == 1); ends = find(transitions == -1) - 1;
    for k = 1:numel(starts)
        first = starts(k); last = ends(k);
        if first > 1 && last < numel(gridValues) && ...
                last - first + 1 <= maximumGapSeconds && ...
                isfinite(gridValues(first-1)) && isfinite(gridValues(last+1))
            gridValues(first:last) = interp1([first-1; last+1], ...
                [gridValues(first-1); gridValues(last+1)], (first:last).', 'linear');
        end
    end
    valid = find(isfinite(gridValues));
    if isempty(valid), return; end
    gridValues(1:valid(1)-1) = gridValues(valid(1));
    gridValues(valid(end)+1:end) = gridValues(valid(end));
end

function statistics = calculateStatistics(values)
    values = values(isfinite(values));
    statistics = struct('mean', mean(values), 'std', std(values, 0), ...
        'p95', nearestRankAbsoluteP95(values), 'count', numel(values));
end

function p95 = nearestRankAbsoluteP95(values)
    values = sort(abs(values(isfinite(values))));
    p95 = values(max(1, ceil(0.95 * numel(values))));
end

function fig = createDifferentialFigure(timeData, values, ~, ~, stats, titleText)
    fig = figure('Color', 'white', 'Name', titleText, 'NumberTitle', 'off', ...
        'Position', [100, 100, 1250, 740]);
    ax = axes(fig);
    ax.Position = [0.09, 0.22, 0.87, 0.70];
    plot(ax, (1:numel(values)).', values, 'LineWidth', 1.0);
    grid(ax, 'on'); box(ax, 'on');
    title(ax, titleText, 'Interpreter', 'none', ...
        'FontName', 'Microsoft YaHei', 'FontWeight', 'bold');
    ylabel(ax, '时差 (ns)', 'FontName', 'Microsoft YaHei');
    annotation(fig, 'textbox', [0.05, 0.105, 0.90, 0.035], ...
        'String', sprintf('%s——%s', char(string(timeData(1), 'yyyy/MM/dd HH:mm:ss')), ...
        char(string(timeData(end), 'yyyy/MM/dd HH:mm:ss'))), ...
        'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
        'FontName', 'Microsoft YaHei', 'FontWeight', 'bold', ...
        'EdgeColor', 'none', 'FitBoxToText', 'off');
    annotation(fig, 'textbox', [0.03, 0.045, 0.94, 0.040], ...
        'String', sprintf('均值：%.2f ns    样本标准差：%.2f ns    绝对值95%%分位值：%.2f ns', ...
        stats.mean, stats.std, stats.p95), 'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle', 'FontName', 'Microsoft YaHei', ...
        'EdgeColor', 'none', 'FitBoxToText', 'off');
end

function saveHighResolutionFigure(fig, outputFile)
    drawnow;
    try
        exportgraphics(fig, outputFile, 'Resolution', 300);
    catch
        print(fig, outputFile, '-dpng', '-r300');
    end
end

function safeName = makeSafeFileName(name)
    safeName = regexprep(char(name), '[<>:"/\\|?*]', '_');
    safeName = regexprep(safeName, '[. ]+$', '');
    if isempty(safeName), error('站点名称无有效文件名。'); end
end
