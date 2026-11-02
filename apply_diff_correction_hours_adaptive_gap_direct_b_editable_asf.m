function [outputFiles, summary] = ...
        apply_diff_correction_hours_adaptive_gap_direct_b_editable_asf( ...
        aCsvFile, bCorrectionFile, generateOutputs, ...
        maximumGapOverrideSeconds, windowHours, asfOverrideNs)
% APPLY_DIFF_CORRECTION_HOURS_ADAPTIVE_GAP_DIRECT_B_EDITABLE_ASF
% 自动选择用户指定时长的最优连续窗口，使用被测站点每分钟modelParam1
% 改正测试点数据；必要时建议最小的短缺口插值上限。ASF先自动计算，
% 交互运行时允许用户确认或手动修改。
%
% 直接运行：
%   apply_diff_correction_hours_adaptive_gap_direct_b_editable_asf
%
% 批处理调用：
%   [files, summary] = apply_diff_correction_hours_adaptive_gap_direct_b_editable_asf( ...
%       aCsvFile, bCorrectionFile, true);
%   第4个参数可指定测试点允许插值的最大连续缺秒数。
%   第5个参数可指定窗口小时数；省略时默认24小时。窗口小时数可以
%   小于24，但换算后必须是整数秒，例如12、6、1.5、0.5。
%   第6个参数可指定手动ASF值（ns）；省略或传入[]时使用自动计算值。
%
% 仅计算、不输出文件和图片（便于测试）：
%   [~, summary] = apply_diff_correction_hours_adaptive_gap_direct_b_editable_asf( ...
%       aCsvFile, bCorrectionFile, false);
%
% 测试点CSV必须包含：time, differentialDelay
% 被测站点CSV必须包含：time, modelParam1
%
% 核心规则：
%   1. 测试点先只补齐孤立单秒缺失；若找不到窗口，则寻找能够恢复
%      有效目标时长窗口的最小连续缺口上限，并在交互运行时要求确认。
%   2. 被测站点建立1分钟规则网格，内部缺分钟线性补齐，首尾用最近值补齐。
%   3. 同一分钟内所有测试点数据使用同一个被测站点modelParam1。
%   4. 差分结果 = 测试点原始时延 - 起点前300秒测试点原始时延均值
%                  - 被测站点改正数。
%   5. 优先搜索整小时起点。若存在绝对值P95不超过100 ns的整小时窗口，
%      在合格窗口中按 |均值|+标准差 最小选择；否则改搜整分钟起点。
%   6. 正式窗口为[start, start+用户指定小时数)，每秒1点。

    %% 0. 固定参数与输出结构
    baselinePointCount = 300;
    p95ThresholdNs = 100;
    initialMaximumGapSeconds = 1;
    warningGapSeconds = 10;
    warningInterpolationRatioPercent = 0.1;

    outputFiles = struct( ...
        'resultCsv', "", ...
        'rawDelay', "", ...
        'asfCorrected', "", ...
        'correction', "", ...
        'differential', "", ...
        'asfDifferentialComparison', "", ...
        'rawDifferentialComparison', "");
    summary = struct();

    programFolder = fileparts(mfilename('fullpath'));
    if isempty(programFolder)
        programFolder = pwd;
    end

    interactiveMode = nargin < 2 || isempty(aCsvFile) || isempty(bCorrectionFile);
    if nargin < 3 || isempty(generateOutputs)
        generateOutputs = true;
    end
    generateOutputs = logical(generateOutputs);
    overrideProvided = nargin >= 4 && ~isempty(maximumGapOverrideSeconds);
    if overrideProvided
        maximumAInterpolationGapSeconds = validatePositiveInteger( ...
            maximumGapOverrideSeconds, 'maximumGapOverrideSeconds');
    else
        maximumAInterpolationGapSeconds = initialMaximumGapSeconds;
    end
    adaptiveGapTriggered = false;
    asfOverrideProvided = nargin >= 6 && ~isempty(asfOverrideNs);

    %% 1. 选择输入文件
    if nargin < 1 || isempty(aCsvFile)
        [aFileName, aFilePath] = uigetfile( ...
            {'*.csv', 'CSV数据文件 (*.csv)'}, ...
            '请选择测试点原始时延CSV', programFolder);
        if isequal(aFileName, 0)
            fprintf('未选择测试点原始时延CSV，程序已结束。\n');
            return;
        end
        aCsvFile = fullfile(aFilePath, aFileName);
    else
        aCsvFile = char(string(aCsvFile));
        [aFilePath, ~, ~] = fileparts(aCsvFile);
    end

    if nargin < 2 || isempty(bCorrectionFile)
        [bFileName, bFilePath] = uigetfile( ...
            {'*.csv', 'CSV改正数文件 (*.csv)'}, ...
            '请选择被测站点差分改正数CSV', programFolder);
        if isequal(bFileName, 0)
            fprintf('未选择被测站点差分改正数CSV，程序已结束。\n');
            return;
        end
        bCorrectionFile = fullfile(bFilePath, bFileName);
    else
        bCorrectionFile = char(string(bCorrectionFile));
    end

    if ~isfile(aCsvFile)
        error('测试点原始时延CSV不存在：%s', aCsvFile);
    end
    if ~isfile(bCorrectionFile)
        error('被测站点差分改正数CSV不存在：%s', bCorrectionFile);
    end

    %% 2. 读取、排序并清理输入数据
    fprintf('正在读取测试点原始时延数据……\n');
    readTimer = tic;
    [aTime, aRawDelay, detectedAName, aReadStatistics] = ...
        readAData(aCsvFile);
    fprintf('测试点读取完成：%d条有效记录，耗时%.3f秒。\n', ...
        numel(aTime), toc(readTimer));

    fprintf('正在读取被测站点差分改正数……\n');
    readTimer = tic;
    [bTime, bModelParam1, detectedBName, bReadStatistics] = ...
        readBCorrectionData(bCorrectionFile);
    fprintf('被测站点读取完成：%d条有效记录，耗时%.3f秒。\n', ...
        numel(bTime), toc(readTimer));

    aStationName = detectedAName;
    bStationName = detectedBName;
    if interactiveMode
        stationAnswers = inputdlg( ...
            {'测试点：', '被测站点：'}, ...
            '确认站点名称', [1, 48], ...
            {char(aStationName), char(bStationName)});
        if isempty(stationAnswers)
            fprintf('未确认站点名称，程序已结束。\n');
            return;
        end
        aStationName = strtrim(string(stationAnswers{1}));
        bStationName = strtrim(string(stationAnswers{2}));
    end
    if strlength(aStationName) == 0
        aStationName = "测试点";
    end
    if strlength(bStationName) == 0
        bStationName = "被测站点";
    end

    %% 3. 设置目标窗口时长
    if interactiveMode
        while true
            windowAnswer = inputdlg( ...
                {'窗口长度（小时，可小于24）：'}, ...
                '设置窗口长度', [1, 44], {'24'});
            if isempty(windowAnswer)
                fprintf('未设置窗口长度，程序已结束。\n');
                return;
            end
            try
                [windowHours, windowPointCount] = ...
                    validateWindowHours(windowAnswer{1});
                break;
            catch validationError
                errordlg(validationError.message, '参数无效', 'modal');
            end
        end
    else
        if nargin < 5 || isempty(windowHours)
            windowHours = 24;
        end
        [windowHours, windowPointCount] = ...
            validateWindowHours(windowHours);
    end
    windowLabel = formatWindowLabel(windowHours);
    fprintf('目标窗口长度：%s（%d个1秒点）。\n', ...
        windowLabel, windowPointCount);

    %% 4. 建立规则网格，必要时自适应扩大短缺口插值上限
    while true
        fprintf('正在建立测试点1秒规则时间网格（最大连续缺口%d秒）……\n', ...
            maximumAInterpolationGapSeconds);
        [allTime, allARaw, aWasInterpolated, ...
            unresolvedAMissingCount, aInterpolationGapLength] = ...
            regularizeAData(aTime, aRawDelay, ...
            maximumAInterpolationGapSeconds);
        aInterpolatedCount = sum(aWasInterpolated);

        if numel(allTime) < windowPointCount + baselinePointCount
            error('公共可处理数据不足%s加前置5分钟。', windowLabel);
        end

        fprintf('正在建立被测站点1分钟改正数网格……\n');
        [allBCorrection, bWasFilledForSecond, bFilledMinuteCount, ...
            bDuplicateMinuteCount] = regularizeAndMatchBCorrection( ...
            bTime, bModelParam1, allTime);

        preliminaryCorrected = allARaw - allBCorrection;
        windowAvailableMask = isfinite(allARaw) & isfinite(allBCorrection) & ...
            isfinite(preliminaryCorrected);
        baselineAvailableMask = isfinite(allARaw);
        windowPrefixStatistics = buildPrefixStatistics( ...
            preliminaryCorrected, windowAvailableMask);
        baselinePrefixStatistics = buildPrefixStatistics( ...
            allARaw, baselineAvailableMask);

        [windowFound, selectedIndex, selectionMode, ...
            minimumHourP95, minuteSearchTriggered, ...
            hourCandidateCount, minuteCandidateCount] = ...
            selectRecommendedWindow(allTime, preliminaryCorrected, ...
            windowPrefixStatistics, baselinePrefixStatistics, ...
            windowPointCount, baselinePointCount, ...
            p95ThresholdNs);
        if windowFound
            break;
        end

        [suggestionFound, suggestion] = findMinimumGapSuggestion( ...
            allTime, allARaw, aWasInterpolated, ...
            maximumAInterpolationGapSeconds, windowPointCount, ...
            baselinePointCount);
        if ~suggestionFound
            error(['即使补齐所有内部缺口，也找不到包含完整前置5分钟和' ...
                '连续%d点（%s）的整分钟窗口。请更换数据文件或时间范围。'], ...
                windowPointCount, windowLabel);
        end

        if overrideProvided
            error(['指定的最大连续缺口%d秒仍无法形成有效%s窗口。' ...
                '至少需要%d秒；请调整第4个参数。'], ...
                maximumAInterpolationGapSeconds, ...
                windowLabel, ...
                suggestion.maximumGapSeconds);
        end

        if interactiveMode
            [newMaximumGap, cancelled] = requestGapDecision( ...
                suggestion, maximumAInterpolationGapSeconds, ...
                windowPointCount, baselinePointCount, ...
                windowLabel, ...
                warningGapSeconds, warningInterpolationRatioPercent);
            if cancelled
                fprintf('用户取消短缺口补齐，程序已结束。\n');
                return;
            end
        else
            newMaximumGap = suggestion.maximumGapSeconds;
            fprintf(['未找到有效窗口；批处理模式自动采用最小建议值%d秒，' ...
                '预计候选中最少插值%d点。\n'], ...
                newMaximumGap, suggestion.minimumInterpolatedPointCount);
        end
        maximumAInterpolationGapSeconds = newMaximumGap;
        adaptiveGapTriggered = true;
    end

    %% 5. 全时段预览（仅交互运行时显示，不保存）
    if interactiveMode && generateOutputs
        createFullPreview(allTime, allARaw, allBCorrection, ...
            aStationName, bStationName);
    end

    %% 6. 提取最终目标窗口并计算结果
    selectedEndIndex = selectedIndex + windowPointCount - 1;
    baselineStartIndex = selectedIndex - baselinePointCount;
    baselineEndIndex = selectedIndex - 1;
    selectedIndices = (selectedIndex:selectedEndIndex).';
    baselineIndices = (baselineStartIndex:baselineEndIndex).';

    selectedTime = allTime(selectedIndices);
    selectedARaw = allARaw(selectedIndices);
    selectedBCorrection = allBCorrection(selectedIndices);
    selectedPreliminary = preliminaryCorrected(selectedIndices);
    selectedAInterpolation = aWasInterpolated(selectedIndices);
    selectedAInterpolationGapLength = ...
        aInterpolationGapLength(selectedIndices);
    selectedBCorrectionFilled = bWasFilledForSecond(selectedIndices);
    analysisIndices = (baselineStartIndex:selectedEndIndex).';
    analysisInterpolationMask = aWasInterpolated(analysisIndices);
    analysisInterpolationGapLength = ...
        aInterpolationGapLength(analysisIndices);
    analysisInterpolatedCount = sum(analysisInterpolationMask);
    analysisInterpolationRatioPercent = 100 * analysisInterpolatedCount / ...
        numel(analysisIndices);
    maximumInterpolatedGapInAnalysis = max( ...
        analysisInterpolationGapLength, [], 'omitnan');

    automaticAsfValue = mean(allARaw(baselineIndices), 'omitnan');
    finalDifferential = selectedPreliminary - automaticAsfValue;
    asfValue = automaticAsfValue;
    asfManualOverrideUsed = false;
    if interactiveMode
        [asfValue, asfCancelled, asfManualOverrideUsed] = ...
            requestAsfValue(automaticAsfValue);
        if asfCancelled
            fprintf('用户取消ASF确认，程序已结束。\n');
            return;
        end
    elseif asfOverrideProvided
        asfValue = validateAsfValue(asfOverrideNs);
        asfManualOverrideUsed = true;
    end
    asfCorrected = selectedARaw - asfValue;

    rawStats = calculateStatistics(selectedARaw);
    asfStats = calculateStatistics(asfCorrected);
    correctionStats = calculateStatistics(selectedBCorrection);
    preliminaryStats = calculateStatistics(selectedPreliminary);
    differentialStats = calculateStatistics(finalDifferential);

    selectedStart = selectedTime(1);
    nominalEnd = selectedStart + seconds(windowPointCount);
    selectedScore = abs(differentialStats.mean) + differentialStats.std;

    if numel(selectedTime) ~= windowPointCount || ...
            seconds(selectedTime(end) - selectedTime(1)) ~= ...
            windowPointCount - 1
        error('内部校验失败：最终窗口不是连续的%d个1秒点。', ...
            windowPointCount);
    end

    summary = struct( ...
        'aStationName', aStationName, ...
        'bStationName', bStationName, ...
        'selectionMode', selectionMode, ...
        'startTime', selectedStart, ...
        'nominalEndTime', nominalEnd, ...
        'lastIncludedTime', selectedTime(end), ...
        'windowHours', windowHours, ...
        'windowPointCount', windowPointCount, ...
        'pointCount', numel(selectedTime), ...
        'score', selectedScore, ...
        'mean', differentialStats.mean, ...
        'std', differentialStats.std, ...
        'p95', differentialStats.p95, ...
        'automaticAsfValue', automaticAsfValue, ...
        'asfValue', asfValue, ...
        'asfManualOverrideUsed', asfManualOverrideUsed, ...
        'asfDifferenceFromAutomatic', asfValue - automaticAsfValue, ...
        'aBaselineMean', automaticAsfValue, ...
        'minimumHourP95', minimumHourP95, ...
        'p95Threshold', p95ThresholdNs, ...
        'minuteSearchTriggered', minuteSearchTriggered, ...
        'hourCandidateCount', hourCandidateCount, ...
        'minuteCandidateCount', minuteCandidateCount, ...
        'maximumAInterpolationGapSeconds', ...
            maximumAInterpolationGapSeconds, ...
        'adaptiveGapTriggered', adaptiveGapTriggered, ...
        'aInterpolatedCountAll', aInterpolatedCount, ...
        'aInterpolatedCountSelected', sum(selectedAInterpolation), ...
        'aInterpolatedCountWithBaseline', analysisInterpolatedCount, ...
        'aInterpolationRatioWithBaselinePercent', ...
            analysisInterpolationRatioPercent, ...
        'aMaximumInterpolatedGapSecondsWithBaseline', ...
            maximumInterpolatedGapInAnalysis, ...
        'aUnresolvedMissingCountAll', unresolvedAMissingCount, ...
        'bFilledMinuteCountAll', bFilledMinuteCount, ...
        'bFilledSecondCountSelected', sum(selectedBCorrectionFilled), ...
        'bDuplicateMinuteCount', bDuplicateMinuteCount, ...
        'aReadStatistics', aReadStatistics, ...
        'bReadStatistics', bReadStatistics);

    printSummary(summary, rawStats, asfStats, correctionStats, ...
        preliminaryStats, differentialStats, aCsvFile, bCorrectionFile);

    if ~generateOutputs
        fprintf('generateOutputs=false：已完成计算验证，未输出CSV和图片。\n');
        return;
    end

    if interactiveMode
        confirmationText = sprintf([ ...
            '已找到最优%s%s窗口。\n' ...
            '时间：[ %s, %s )\n' ...
            '点数：%d\n' ...
            '综合得分：%.2f ns\n' ...
            '绝对值P95：%.2f ns\n' ...
            '差分公式：A原始时延-A前5分钟均值-B改正数\n' ...
            '自动计算ASF：%.2f ns\n' ...
            '实际采用ASF：%.2f ns（%s）\n' ...
            '测试点最大允许连续缺口：%d秒\n' ...
            '窗口及前置5分钟插值：%d点（%.4f%%）\n' ...
            '其中最长插值缺口：%d秒\n\n' ...
            '是否生成结果CSV和6张图片？'], ...
            selectionMode, windowLabel, ...
            char(string(selectedStart, 'yyyy-MM-dd HH:mm:ss')), ...
            char(string(nominalEnd, 'yyyy-MM-dd HH:mm:ss')), ...
            windowPointCount, selectedScore, differentialStats.p95, ...
            automaticAsfValue, asfValue, ...
            asfSourceText(asfManualOverrideUsed), ...
            maximumAInterpolationGapSeconds, ...
            analysisInterpolatedCount, analysisInterpolationRatioPercent, ...
            maximumInterpolatedGapInAnalysis);
        confirmation = questdlg(confirmationText, '确认输出结果', ...
            '生成结果', '取消', '生成结果');
        if ~strcmp(confirmation, '生成结果')
            fprintf('用户取消输出，计算结果未写入文件。\n');
            return;
        end
    end

    %% 7. 输出中文字段CSV
    safeAName = makeSafeFileName(aStationName);
    safeBName = makeSafeFileName(bStationName);
    startText = char(string(selectedStart, 'yyyyMMddHHmmss'));
    endText = char(string(nominalEnd, 'yyyyMMddHHmmss'));
    outputBaseName = sprintf( ...
        '%s改%s_%s_%s_自适应缺口最优%s_ASF可修改版_直接减B', ...
        safeBName, safeAName, startText, endText, windowLabel);

    % 每次运行使用独立结果目录，日期取自A输入文件名。
    [~, aInputBaseName, ~] = fileparts(aCsvFile);
    inputDate = regexp(aInputBaseName, '\d{4}-\d{2}-\d{2}', 'match', 'once');
    if isempty(inputDate)
        error('A输入文件名中未找到yyyy-MM-dd格式的日期，无法命名结果目录。');
    end
    resultRoot = fullfile(fileparts(programFolder), 'result');
    runFolderName = sprintf('%s改%s_%s', ...
        makeSafeFileName(detectedBName), makeSafeFileName(detectedAName), inputDate);
    outputFolder = fullfile(resultRoot, runFolderName);
    runNumber = 2;
    while isfolder(outputFolder) || isfile(outputFolder)
        outputFolder = fullfile(resultRoot, ...
            sprintf('%s_%02d', runFolderName, runNumber));
        runNumber = runNumber + 1;
    end
    [folderCreated, folderMessage] = mkdir(outputFolder);
    if ~folderCreated
        error('无法创建结果目录：%s', folderMessage);
    end

    selectedTime.Format = 'yyyy-MM-dd HH:mm:ss';
    aInterpolationText = repmat("否", windowPointCount, 1);
    aInterpolationText(selectedAInterpolation) = "是";
    bFilledText = repmat("否", windowPointCount, 1);
    bFilledText(selectedBCorrectionFilled) = "是";

    resultTable = table(selectedTime, selectedARaw, ...
        selectedBCorrection, selectedPreliminary, asfCorrected, ...
        finalDifferential, aInterpolationText, ...
        selectedAInterpolationGapLength, bFilledText, ...
        'VariableNames', {'时间', '测试点原始时延_ns', ...
        '被测站点改正数_modelParam1_ns', '原始时延减改正数_ns', ...
        'ASF修正结果_ns', '最终差分结果_ns', ...
        '测试点原始数据是否插值', ...
        '测试点插值所属连续缺口长度_秒', ...
        '被测站点改正数是否补齐'});

    outputFiles.resultCsv = string(fullfile(outputFolder, ...
        [outputBaseName, '_处理结果.csv']));
    writetable(resultTable, outputFiles.resultCsv, ...
        'Delimiter', ',', 'Encoding', 'UTF-8');

    %% 8. 按手动程序风格生成6张正式图
    outputFiles.rawDelay = string(fullfile(outputFolder, ...
        [outputBaseName, '_图1_差分前原始时延.png']));
    rawStatisticsText = sprintf('均值：%.2f ns\n标准差：%.2f ns', ...
        rawStats.mean, rawStats.std);
    createSingleSeriesFigure(selectedTime, selectedARaw, ...
        '差分前时差', sprintf('%s差分前时差', aStationName), ...
        rawStatisticsText, outputFiles.rawDelay, nominalEnd);

    outputFiles.asfCorrected = string(fullfile(outputFolder, ...
        [outputBaseName, '_图2_差分前时差减ASF.png']));
    createSingleSeriesFigure(selectedTime, asfCorrected, ...
        '差分前-ASF', sprintf('%s站用户定时精度（ASF修正）测试结果', ...
        bStationName), formatAsfStatistics(asfStats), ...
        outputFiles.asfCorrected, nominalEnd);

    correctionMinuteMask = second(selectedTime) == 0;
    correctionMinuteTime = selectedTime(correctionMinuteMask);
    correctionMinuteValues = selectedBCorrection(correctionMinuteMask);
    outputFiles.correction = string(fullfile(outputFolder, ...
        [outputBaseName, '_图3_差分改正数.png']));
    createSingleSeriesFigure(correctionMinuteTime, ...
        correctionMinuteValues, 'modelParam1', ...
        sprintf('%s站差分改正数', bStationName), ...
        formatFullStatistics(correctionStats), ...
        outputFiles.correction, nominalEnd);

    outputFiles.differential = string(fullfile(outputFolder, ...
        [outputBaseName, '_图4_差分后数据.png']));
    createSingleSeriesFigure(selectedTime, finalDifferential, ...
        '自行计算差分后数据', ...
        sprintf('%s差分后数据', aStationName), ...
        formatFullStatistics(differentialStats), ...
        outputFiles.differential, nominalEnd);

    outputFiles.asfDifferentialComparison = string(fullfile(outputFolder, ...
        [outputBaseName, '_图5_ASF修正与实时差分结果对比.png']));
    asfComparisonStatistics = sprintf([ ...
        'ASF修正：均值 %.2f ns，标准差 %.2f ns，95%%分位值 %.2f ns\n' ...
        '实时差分：均值 %.2f ns，标准差 %.2f ns，95%%分位值 %.2f ns'], ...
        asfStats.mean, asfStats.std, asfStats.p95, ...
        differentialStats.mean, differentialStats.std, ...
        differentialStats.p95);
    createMultiSeriesFigure(selectedTime, ...
        [asfCorrected, finalDifferential], ...
        {'准确度（ASF修正）', '准确度（实时差分）'}, ...
        sprintf('%s站差分改正结果对比', bStationName), ...
        asfComparisonStatistics, ...
        outputFiles.asfDifferentialComparison, nominalEnd);

    outputFiles.rawDifferentialComparison = string(fullfile(outputFolder, ...
        [outputBaseName, '_图6_差分前后结果对比.png']));
    rawComparisonStatistics = sprintf([ ...
        '差分前：均值 %.2f ns，标准差 %.2f ns\n' ...
        '差分后：均值 %.2f ns，标准差 %.2f ns，95%%分位值 %.2f ns'], ...
        rawStats.mean, rawStats.std, differentialStats.mean, ...
        differentialStats.std, differentialStats.p95);
    createMultiSeriesFigure(selectedTime, ...
        [selectedARaw, finalDifferential], {'差分前', '差分后'}, ...
        sprintf('%s站差分改正效果', bStationName), ...
        rawComparisonStatistics, ...
        outputFiles.rawDifferentialComparison, nominalEnd);

    fprintf('结果CSV和6张PNG图片已保存到：%s\n', outputFolder);
end


function [timeData, delayData, stationName, statistics] = readAData(inputFile)
% READDATA 读取测试点time和differentialDelay。

    requiredColumns = {'time', 'differentialDelay'};
    [source, usedEncoding] = readSelectedCsv(inputFile, ...
        requiredColumns, {'stationName'}, '测试点原始时延CSV');

    timeData = parseTimeVector(string(source.('time')), '测试点时间');
    delayData = double(source.('differentialDelay'));
    stationName = extractStationName(source, '测试点');

    validRows = ~isnat(timeData) & isfinite(delayData);
    statistics = struct( ...
        'totalCount', height(source), ...
        'validCount', sum(validRows), ...
        'invalidCount', sum(~validRows), ...
        'duplicateTimeCount', 0, ...
        'encoding', string(usedEncoding));
    if ~any(validRows)
        error('测试点原始时延CSV中没有有效的time和differentialDelay数据。');
    end

    timeData = timeData(validRows);
    delayData = delayData(validRows);
    [timeData, sortIndex] = sort(timeData);
    delayData = delayData(sortIndex);

    [uniqueTime, uniqueIndex] = unique(timeData, 'last');
    statistics.duplicateTimeCount = numel(timeData) - numel(uniqueTime);
    if statistics.duplicateTimeCount > 0
        warning('测试点存在%d条重复时间戳，已保留相同时间的最后一条。', ...
            statistics.duplicateTimeCount);
    end
    timeData = uniqueTime;
    delayData = delayData(uniqueIndex);
end


function [timeData, modelParam1, stationName, statistics] = ...
        readBCorrectionData(inputFile)
% READBCORRECTIONDATA 读取被测站点time和modelParam1。

    requiredColumns = {'time', 'modelParam1'};
    [source, usedEncoding] = readSelectedCsv(inputFile, ...
        requiredColumns, {'stationName'}, '被测站点差分改正数CSV');

    timeData = parseTimeVector(string(source.('time')), '被测站点改正数时间');
    modelParam1 = double(source.('modelParam1'));
    stationName = extractStationName(source, '被测站点');

    validRows = ~isnat(timeData) & isfinite(modelParam1);
    statistics = struct( ...
        'totalCount', height(source), ...
        'validCount', sum(validRows), ...
        'invalidCount', sum(~validRows), ...
        'encoding', string(usedEncoding));
    if ~any(validRows)
        error('被测站点差分改正数CSV中没有有效的time和modelParam1数据。');
    end

    timeData = timeData(validRows);
    modelParam1 = modelParam1(validRows);
    [timeData, sortIndex] = sort(timeData);
    modelParam1 = modelParam1(sortIndex);
end


function [source, usedEncoding] = readSelectedCsv( ...
        inputFile, requiredColumns, optionalColumns, sourceLabel)
% READSELECTEDCSV 尝试UTF-8和GBK，只读取需要的字段。

    candidateEncodings = {'UTF-8', 'GBK'};
    lastError = '';
    for encodingIndex = 1:numel(candidateEncodings)
        usedEncoding = candidateEncodings{encodingIndex};
        try
            options = detectImportOptions(inputFile, ...
                'FileType', 'text', 'Delimiter', ',', ...
                'Encoding', usedEncoding, ...
                'VariableNamingRule', 'preserve');
            if ~all(ismember(requiredColumns, options.VariableNames))
                error('%s缺少必要字段：%s', sourceLabel, ...
                    strjoin(requiredColumns, '、'));
            end
            selectedNames = requiredColumns;
            for optionalIndex = 1:numel(optionalColumns)
                if ismember(optionalColumns{optionalIndex}, ...
                        options.VariableNames)
                    selectedNames{end + 1} = optionalColumns{optionalIndex}; %#ok<AGROW>
                end
            end
            options.SelectedVariableNames = selectedNames;
            options = setvartype(options, requiredColumns{1}, 'string');
            options = setvartype(options, requiredColumns{2}, 'double');
            if ismember('stationName', selectedNames)
                options = setvartype(options, 'stationName', 'string');
            end
            source = readtable(inputFile, options);
            return;
        catch ME
            lastError = ME.message;
        end
    end
    error('无法读取%s：%s', sourceLabel, lastError);
end


function stationName = extractStationName(source, fallbackName)
% EXTRACTSTATIONNAME 提取首个非空站名。

    stationName = string(fallbackName);
    if ~ismember('stationName', source.Properties.VariableNames)
        return;
    end
    names = strtrim(string(source.('stationName')));
    validNameIndex = find(~ismissing(names) & strlength(names) > 0, 1);
    if ~isempty(validNameIndex)
        stationName = names(validNameIndex);
    end
end


function timeData = parseTimeVector(timeText, sourceLabel)
% PARSETIMEVECTOR 兼容常用的两种秒级时间格式。

    timeText = strtrim(string(timeText));
    timeData = NaT(numel(timeText), 1, ...
        'Format', 'yyyy-MM-dd HH:mm:ss');
    supportedFormats = {'yyyy-MM-dd HH:mm:ss', 'MM/dd/yyyy HH:mm:ss'};

    for formatIndex = 1:numel(supportedFormats)
        pendingIndex = find(isnat(timeData) & strlength(timeText) > 0);
        if isempty(pendingIndex)
            break;
        end
        try
            parsed = datetime(timeText(pendingIndex), ...
                'InputFormat', supportedFormats{formatIndex}, ...
                'Format', 'yyyy-MM-dd HH:mm:ss');
            succeeded = ~isnat(parsed);
            timeData(pendingIndex(succeeded)) = parsed(succeeded);
        catch
            for elementIndex = reshape(pendingIndex, 1, [])
                try
                    parsed = datetime(timeText(elementIndex), ...
                        'InputFormat', supportedFormats{formatIndex}, ...
                        'Format', 'yyyy-MM-dd HH:mm:ss');
                    if ~isnat(parsed)
                        timeData(elementIndex) = parsed;
                    end
                catch
                end
            end
        end
    end
    if all(isnat(timeData))
        error('%s无法按支持的时间格式解析。', sourceLabel);
    end
end


function integerValue = validatePositiveInteger(rawValue, fieldName)
% VALIDATEPOSITIVEINTEGER 校验正整数参数。

    numericValue = double(rawValue);
    if ~isscalar(numericValue) || ~isfinite(numericValue) || ...
            numericValue < 1 || numericValue ~= fix(numericValue)
        error('%s必须是大于等于1的整数。', fieldName);
    end
    integerValue = numericValue;
end


function [hoursValue, pointCount] = validateWindowHours(rawValue)
% VALIDATEWINDOWHOURS 校验窗口小时数，并换算为整数秒点数。

    if ischar(rawValue) || isstring(rawValue)
        if ~isscalar(string(rawValue))
            error('窗口小时数必须是单个数值。');
        end
        numericValue = str2double(strtrim(string(rawValue)));
    else
        numericValue = double(rawValue);
    end
    if ~isscalar(numericValue) || ~isfinite(numericValue) || ...
            numericValue <= 0
        error('窗口小时数必须是大于0的数值。');
    end

    rawPointCount = numericValue * 3600;
    pointCount = round(rawPointCount);
    tolerance = 32 * eps(max(1, abs(rawPointCount)));
    if abs(rawPointCount - pointCount) > tolerance
        error('窗口小时数换算后必须是整数秒。');
    end
    hoursValue = pointCount / 3600;
end


function label = formatWindowLabel(windowHours)
% FORMATWINDOWLABEL 生成用于提示和文件名的简洁时长文本。

    label = sprintf('%.10g小时', windowHours);
end


function [asfValue, cancelled, manualOverrideUsed] = ...
        requestAsfValue(automaticAsfValue)
% REQUESTASFVALUE 显示自动ASF，并允许用户确认或手动修改。

    asfValue = automaticAsfValue;
    cancelled = false;
    manualOverrideUsed = false;
    promptText = sprintf([ ...
        '程序根据窗口起点前300秒自动算得ASF为 %.6f ns。\n' ...
        '直接确认即使用自动值；如需修改，请输入新的ASF值（ns）：'], ...
        automaticAsfValue);
    defaultText = sprintf('%.17g', automaticAsfValue);

    while true
        answer = inputdlg({promptText}, '确认或修改ASF', ...
            [1, 58], {defaultText});
        if isempty(answer)
            cancelled = true;
            return;
        end
        try
            asfValue = validateAsfValue(answer{1});
            comparisonTolerance = 32 * eps(max(1, ...
                abs(automaticAsfValue)));
            manualOverrideUsed = abs(asfValue - automaticAsfValue) > ...
                comparisonTolerance;
            return;
        catch validationError
            errordlg(validationError.message, 'ASF参数无效', 'modal');
        end
    end
end


function value = validateAsfValue(rawValue)
% VALIDATEASFVALUE 校验ASF为有限标量。

    if ischar(rawValue) || isstring(rawValue)
        if ~isscalar(string(rawValue))
            error('ASF值必须是单个数值。');
        end
        numericValue = str2double(strtrim(string(rawValue)));
    else
        numericValue = double(rawValue);
    end
    if ~isscalar(numericValue) || ~isfinite(numericValue)
        error('ASF值必须是有限数值。');
    end
    value = numericValue;
end


function textValue = asfSourceText(manualOverrideUsed)
% ASFSOURCETEXT 返回ASF来源说明。

    if manualOverrideUsed
        textValue = '手动设置';
    else
        textValue = '自动计算';
    end
end


function [windowFound, selectedIndex, selectionMode, ...
        minimumHourP95, minuteSearchTriggered, ...
        hourCandidateCount, minuteCandidateCount] = ...
        selectRecommendedWindow(timeData, preliminaryCorrected, ...
        windowPrefix, baselinePrefix, ...
        windowLength, baselineLength, p95Threshold)
% SELECTRECOMMENDEDWINDOW 按原规则先选整小时，必要时再选整分钟。

    windowFound = false;
    selectedIndex = NaN;
    selectionMode = "";
    minimumHourP95 = NaN;
    minuteSearchTriggered = false;
    minuteCandidateCount = 0;

    wholeHourIndex = find(second(timeData) == 0 & minute(timeData) == 0);
    hourCandidates = evaluateCandidates(timeData, preliminaryCorrected, ...
        windowPrefix, baselinePrefix, wholeHourIndex, ...
        windowLength, baselineLength);
    hourCandidateCount = numel(hourCandidates.startIndex);

    if hourCandidateCount > 0
        fprintf('正在计算%d个整小时候选窗口的绝对值P95……\n', ...
            hourCandidateCount);
        hourCandidates.p95 = calculateCandidateP95( ...
            preliminaryCorrected, hourCandidates.startIndex, ...
            hourCandidates.baselineMean, windowLength);
        minimumHourP95 = min(hourCandidates.p95);
        qualifiedPositions = find(hourCandidates.p95 <= p95Threshold);
        if ~isempty(qualifiedPositions)
            selectedPosition = chooseBestCandidate( ...
                hourCandidates, qualifiedPositions);
            selectedIndex = hourCandidates.startIndex(selectedPosition);
            selectionMode = "整小时";
            windowFound = true;
            return;
        end
        fprintf(['所有整小时窗口的绝对值P95均超过%.2f ns，' ...
            '开始搜索整分钟窗口……\n'], p95Threshold);
    else
        fprintf('当前缺口设置下没有完整的整小时候选，开始搜索整分钟窗口……\n');
    end

    minuteSearchTriggered = true;
    wholeMinuteIndex = find(second(timeData) == 0);
    minuteCandidates = evaluateCandidates(timeData, ...
        preliminaryCorrected, windowPrefix, baselinePrefix, ...
        wholeMinuteIndex, ...
        windowLength, baselineLength);
    minuteCandidateCount = numel(minuteCandidates.startIndex);
    if minuteCandidateCount == 0
        return;
    end

    selectedPosition = chooseBestMinuteCandidate( ...
        preliminaryCorrected, minuteCandidates, windowLength);
    selectedIndex = minuteCandidates.startIndex(selectedPosition);
    selectionMode = "整分钟";
    windowFound = true;
end


function [suggestionFound, suggestion] = findMinimumGapSuggestion( ...
        timeData, currentValues, alreadyInterpolatedMask, ...
        currentMaximumGap, windowLength, baselineLength)
% FINDMINIMUMGAPSUGGESTION 找到能形成完整窗口的最小额外缺口上限。

    suggestionFound = false;
    suggestion = struct( ...
        'maximumGapSeconds', NaN, ...
        'candidateType', "", ...
        'candidateCount', 0, ...
        'minimumInterpolatedPointCount', NaN, ...
        'minimumInterpolationRatioPercent', NaN);

    missingMask = ~isfinite(currentValues);
    transitions = diff([false; missingMask; false]);
    gapStarts = find(transitions == 1);
    gapEnds = find(transitions == -1) - 1;
    fillableGapLengthAtPoint = zeros(size(currentValues));
    for gapIndex = 1:numel(gapStarts)
        firstMissing = gapStarts(gapIndex);
        lastMissing = gapEnds(gapIndex);
        gapLength = lastMissing - firstMissing + 1;
        internalGap = firstMissing > 1 && ...
            lastMissing < numel(currentValues) && ...
            isfinite(currentValues(firstMissing - 1)) && ...
            isfinite(currentValues(lastMissing + 1));
        if internalGap && gapLength > currentMaximumGap
            fillableGapLengthAtPoint(firstMissing:lastMissing) = gapLength;
        end
    end

    candidateThresholds = unique(fillableGapLengthAtPoint( ...
        fillableGapLengthAtPoint > 0));
    if isempty(candidateThresholds)
        return;
    end

    hourStartIndex = find(second(timeData) == 0 & minute(timeData) == 0);
    minuteStartIndex = find(second(timeData) == 0);
    bestThresholdPosition = NaN;
    lowerPosition = 1;
    upperPosition = numel(candidateThresholds);
    while lowerPosition <= upperPosition
        middlePosition = floor((lowerPosition + upperPosition) / 2);
        threshold = candidateThresholds(middlePosition);
        newlyFillable = fillableGapLengthAtPoint > 0 & ...
            fillableGapLengthAtPoint <= threshold;
        availableMask = isfinite(currentValues) | newlyFillable;
        hourValid = findCompleteStartIndices(availableMask, ...
            hourStartIndex, windowLength, baselineLength);
        if isempty(hourValid)
            minuteValid = findCompleteStartIndices(availableMask, ...
                minuteStartIndex, windowLength, baselineLength);
        else
            minuteValid = zeros(0, 1);
        end
        if ~isempty(hourValid) || ~isempty(minuteValid)
            bestThresholdPosition = middlePosition;
            upperPosition = middlePosition - 1;
        else
            lowerPosition = middlePosition + 1;
        end
    end
    if isnan(bestThresholdPosition)
        return;
    end

    threshold = candidateThresholds(bestThresholdPosition);
    newlyFillable = fillableGapLengthAtPoint > 0 & ...
        fillableGapLengthAtPoint <= threshold;
    availableMask = isfinite(currentValues) | newlyFillable;
    hourValid = findCompleteStartIndices(availableMask, hourStartIndex, ...
        windowLength, baselineLength);
    if ~isempty(hourValid)
        validStartIndex = hourValid;
        candidateType = "整小时";
    else
        validStartIndex = findCompleteStartIndices(availableMask, ...
            minuteStartIndex, windowLength, baselineLength);
        candidateType = "整分钟";
    end
    if isempty(validStartIndex)
        return;
    end

    totalInterpolationMask = alreadyInterpolatedMask | newlyFillable;
    interpolationPrefix = [0; cumsum(double(totalInterpolationMask))];
    intervalStart = validStartIndex - baselineLength;
    intervalEnd = validStartIndex + windowLength - 1;
    interpolationCounts = interpolationPrefix(intervalEnd + 1) - ...
        interpolationPrefix(intervalStart);

    suggestionFound = true;
    suggestion.maximumGapSeconds = threshold;
    suggestion.candidateType = candidateType;
    suggestion.candidateCount = numel(validStartIndex);
    suggestion.minimumInterpolatedPointCount = min(interpolationCounts);
    suggestion.minimumInterpolationRatioPercent = 100 * ...
        suggestion.minimumInterpolatedPointCount / ...
        (windowLength + baselineLength);
end


function validStartIndex = findCompleteStartIndices( ...
        availableMask, proposedStartIndex, windowLength, baselineLength)
% FINDCOMPLETESTARTINDICES 仅按有效点数量筛出完整候选起点。

    proposedStartIndex = proposedStartIndex(:);
    withinBounds = proposedStartIndex > baselineLength & ...
        proposedStartIndex + windowLength - 1 <= numel(availableMask);
    startIndex = proposedStartIndex(withinBounds);
    if isempty(startIndex)
        validStartIndex = zeros(0, 1);
        return;
    end
    endIndex = startIndex + windowLength - 1;
    countPrefix = [0; cumsum(double(availableMask))];
    windowCount = countPrefix(endIndex + 1) - countPrefix(startIndex);
    baselineCount = countPrefix(startIndex) - ...
        countPrefix(startIndex - baselineLength);
    validStartIndex = startIndex(windowCount == windowLength & ...
        baselineCount == baselineLength);
end


function [newMaximumGap, cancelled] = requestGapDecision( ...
        suggestion, currentMaximumGap, windowLength, baselineLength, ...
        windowLabel, ...
        warningGapSeconds, warningRatioPercent)
% REQUESTGAPDECISION 显示自适应建议，并允许采用或手动设置。

    newMaximumGap = currentMaximumGap;
    cancelled = false;
    highRisk = suggestion.maximumGapSeconds > warningGapSeconds || ...
        suggestion.minimumInterpolationRatioPercent > warningRatioPercent;
    warningText = '';
    defaultChoice = '采用建议值';
    if highRisk
        warningText = sprintf([ ...
            '\n\n警告：建议值超过程序的常规提醒范围' ...
            '（缺口>%d秒或插值比例>%.3f%%），请谨慎确认。'], ...
            warningGapSeconds, warningRatioPercent);
        defaultChoice = '取消';
    end
    messageText = sprintf([ ...
        '按当前最大连续缺口%d秒，没有可用的%s窗口。\n\n' ...
        '最小建议值：%d秒\n' ...
        '可恢复的%s候选：%d个\n' ...
        '候选中至少需要插值：%d点（含前置%d秒，共%d点）\n' ...
        '最低插值比例：%.4f%%%s'], ...
        currentMaximumGap, windowLabel, suggestion.maximumGapSeconds, ...
        suggestion.candidateType, suggestion.candidateCount, ...
        suggestion.minimumInterpolatedPointCount, baselineLength, ...
        windowLength + baselineLength, ...
        suggestion.minimumInterpolationRatioPercent, warningText);
    choice = questdlg(messageText, '短缺口自适应补齐', ...
        '采用建议值', '手动设置', '取消', defaultChoice);
    if isempty(choice) || strcmp(choice, '取消')
        cancelled = true;
        return;
    end
    if strcmp(choice, '采用建议值')
        newMaximumGap = suggestion.maximumGapSeconds;
        return;
    end

    while true
        answer = inputdlg( ...
            {'允许线性插值的最大连续缺秒数：'}, ...
            '手动设置短缺口上限', [1, 46], ...
            {num2str(suggestion.maximumGapSeconds)});
        if isempty(answer)
            cancelled = true;
            return;
        end
        manualValue = str2double(strtrim(answer{1}));
        if ~isfinite(manualValue) || manualValue <= currentMaximumGap || ...
                manualValue ~= fix(manualValue)
            errordlg(sprintf('请输入大于当前值%d的整数秒数。', ...
                currentMaximumGap), '参数无效', 'modal');
            continue;
        end
        if manualValue > warningGapSeconds
            riskChoice = questdlg(sprintf([ ...
                '你输入了%d秒，超过%d秒的常规提醒值。' ...
                '较长缺口插值可能改变数据特征，是否继续？'], ...
                manualValue, warningGapSeconds), ...
                '较长缺口提醒', '继续', '返回修改', ...
                '返回修改');
            if ~strcmp(riskChoice, '继续')
                continue;
            end
        end
        newMaximumGap = manualValue;
        return;
    end
end


function [gridTime, gridValues, interpolatedMask, unresolvedCount, ...
        interpolationGapLength] = ...
        regularizeAData(timeData, values, maximumGapLength)
% REGULARIZEADATA 建立1秒网格，只插值不超过maximumGapLength的内部缺口。

    gridTime = (timeData(1):seconds(1):timeData(end)).';
    gridValues = nan(numel(gridTime), 1);
    interpolationGapLength = zeros(numel(gridTime), 1);
    [matched, sourceIndex] = ismember(gridTime, timeData);
    gridValues(matched) = values(sourceIndex(matched));

    originallyMissing = ~isfinite(gridValues);
    missingTransitions = diff([false; originallyMissing; false]);
    gapStarts = find(missingTransitions == 1);
    gapEnds = find(missingTransitions == -1) - 1;

    for gapIndex = 1:numel(gapStarts)
        firstMissing = gapStarts(gapIndex);
        lastMissing = gapEnds(gapIndex);
        gapLength = lastMissing - firstMissing + 1;
        canInterpolate = gapLength <= maximumGapLength && ...
            firstMissing > 1 && lastMissing < numel(gridValues) && ...
            isfinite(gridValues(firstMissing - 1)) && ...
            isfinite(gridValues(lastMissing + 1));
        if canInterpolate
            interpolationIndex = (firstMissing:lastMissing).';
            gridValues(interpolationIndex) = interp1( ...
                [firstMissing - 1; lastMissing + 1], ...
                [gridValues(firstMissing - 1); ...
                 gridValues(lastMissing + 1)], ...
                interpolationIndex, 'linear');
            interpolationGapLength(interpolationIndex) = gapLength;
        end
    end

    interpolatedMask = originallyMissing & isfinite(gridValues);
    unresolvedCount = sum(~isfinite(gridValues));
end


function [correctionPerSecond, filledPerSecond, filledMinuteCount, ...
        duplicateMinuteCount] = regularizeAndMatchBCorrection( ...
        bTime, bParam1, secondGridTime)
% REGULARIZEANDMATCHBCORRECTION 每分钟保留最后一条并补齐所有缺分钟。

    bMinute = dateshift(bTime, 'start', 'minute');
    [uniqueMinute, uniqueIndex] = unique(bMinute, 'last');
    uniqueParam1 = bParam1(uniqueIndex);
    duplicateMinuteCount = numel(bMinute) - numel(uniqueMinute);

    firstRequiredMinute = dateshift(secondGridTime(1), 'start', 'minute');
    lastRequiredMinute = dateshift(secondGridTime(end), 'start', 'minute');
    minuteGrid = (firstRequiredMinute:minutes(1):lastRequiredMinute).';
    minuteValues = nan(numel(minuteGrid), 1);
    [matched, sourceIndex] = ismember(minuteGrid, uniqueMinute);
    minuteValues(matched) = uniqueParam1(sourceIndex(matched));
    originallyMissing = ~isfinite(minuteValues);

    validIndex = find(isfinite(minuteValues));
    if isempty(validIndex)
        error('被测站点改正数与测试点时间范围完全不重叠，无法补齐。');
    elseif isscalar(validIndex)
        filledMinuteValues = repmat(minuteValues(validIndex), ...
            numel(minuteValues), 1);
    else
        allIndex = (1:numel(minuteValues)).';
        filledMinuteValues = interp1(validIndex, ...
            minuteValues(validIndex), allIndex, 'linear', NaN);
        filledMinuteValues(1:validIndex(1) - 1) = ...
            minuteValues(validIndex(1));
        filledMinuteValues(validIndex(end) + 1:end) = ...
            minuteValues(validIndex(end));
    end
    filledMinuteMask = originallyMissing & isfinite(filledMinuteValues);
    filledMinuteCount = sum(filledMinuteMask);

    minuteOffset = round(minutes( ...
        dateshift(secondGridTime, 'start', 'minute') - firstRequiredMinute));
    minuteIndex = minuteOffset + 1;
    correctionPerSecond = filledMinuteValues(minuteIndex);
    filledPerSecond = filledMinuteMask(minuteIndex);
end


function prefix = buildPrefixStatistics(values, availableMask)
% BUILDPREFIXSTATISTICS 为快速窗口统计构建累计量。

    finiteValues = values;
    finiteValues(~availableMask) = 0;
    prefix.sum = [0; cumsum(finiteValues)];
    prefix.sumSquares = [0; cumsum(finiteValues .^ 2)];
    prefix.count = [0; cumsum(double(availableMask))];
end


function candidates = evaluateCandidates(timeData, values, ...
        windowPrefix, baselinePrefix, proposedStartIndex, ...
        windowLength, baselineLength)
% EVALUATECANDIDATES 快速计算候选窗口的均值、标准差和综合得分。

    proposedStartIndex = proposedStartIndex(:);
    withinBounds = proposedStartIndex > baselineLength & ...
        proposedStartIndex + windowLength - 1 <= numel(values);
    startIndex = proposedStartIndex(withinBounds);
    endIndex = startIndex + windowLength - 1;

    windowCount = windowPrefix.count(endIndex + 1) - ...
        windowPrefix.count(startIndex);
    baselineCount = baselinePrefix.count(startIndex) - ...
        baselinePrefix.count(startIndex - baselineLength);
    validCandidate = windowCount == windowLength & ...
        baselineCount == baselineLength;
    startIndex = startIndex(validCandidate);
    endIndex = endIndex(validCandidate);

    if isempty(startIndex)
        candidates = emptyCandidates();
        return;
    end

    windowSum = windowPrefix.sum(endIndex + 1) - ...
        windowPrefix.sum(startIndex);
    windowSquareSum = windowPrefix.sumSquares(endIndex + 1) - ...
        windowPrefix.sumSquares(startIndex);
    baselineSum = baselinePrefix.sum(startIndex) - ...
        baselinePrefix.sum(startIndex - baselineLength);

    windowMean = windowSum / windowLength;
    baselineMean = baselineSum / baselineLength;
    residualMean = windowMean - baselineMean;
    varianceNumerator = windowSquareSum - ...
        (windowSum .^ 2) / windowLength;
    windowStd = sqrt(max(varianceNumerator, 0) / (windowLength - 1));

    candidates = struct( ...
        'startIndex', startIndex, ...
        'startTime', timeData(startIndex), ...
        'baselineMean', baselineMean, ...
        'mean', residualMean, ...
        'std', windowStd, ...
        'score', abs(residualMean) + windowStd, ...
        'p95', nan(size(startIndex)));
end


function candidates = emptyCandidates()
% EMPTYCANDIDATES 返回字段完整的空候选结构。

    candidates = struct( ...
        'startIndex', zeros(0, 1), ...
        'startTime', NaT(0, 1), ...
        'baselineMean', zeros(0, 1), ...
        'mean', zeros(0, 1), ...
        'std', zeros(0, 1), ...
        'score', zeros(0, 1), ...
        'p95', zeros(0, 1));
end


function p95Values = calculateCandidateP95( ...
        preliminaryCorrected, startIndices, baselineMeans, windowLength)
% CALCULATECANDIDATEP95 精确计算候选窗口的绝对值P95。

    p95Values = nan(numel(startIndices), 1);
    for candidateIndex = 1:numel(startIndices)
        firstIndex = startIndices(candidateIndex);
        lastIndex = firstIndex + windowLength - 1;
        residual = preliminaryCorrected(firstIndex:lastIndex) - ...
            baselineMeans(candidateIndex);
        p95Values(candidateIndex) = nearestRankAbsoluteP95(residual);
    end
end


function selectedPosition = chooseBestCandidate(candidates, positions)
% CHOOSEBESTCANDIDATE 按得分、P95、绝对均值、起点依次排序。

    positions = positions(:);
    rankingMatrix = [candidates.score(positions), ...
        candidates.p95(positions), abs(candidates.mean(positions)), ...
        double(candidates.startIndex(positions))];
    [~, order] = sortrows(rankingMatrix, [1, 2, 3, 4]);
    selectedPosition = positions(order(1));
end


function selectedPosition = chooseBestMinuteCandidate( ...
        preliminaryCorrected, candidates, windowLength)
% CHOOSEBESTMINUTECANDIDATE 主指标相同时才计算并比较P95。

    minimumScore = min(candidates.score);
    scoreTolerance = max(1e-12, 32 * eps(max(1, abs(minimumScore))));
    tiedPositions = find(abs(candidates.score - minimumScore) <= ...
        scoreTolerance);

    tiedP95 = calculateCandidateP95(preliminaryCorrected, ...
        candidates.startIndex(tiedPositions), ...
        candidates.baselineMean(tiedPositions), windowLength);
    candidates.p95(tiedPositions) = tiedP95;
    selectedPosition = chooseBestCandidate(candidates, tiedPositions);
end


function statistics = calculateStatistics(values)
% CALCULATESTATISTICS 计算均值、样本标准差和绝对值P95。

    validValues = values(isfinite(values));
    if isempty(validValues)
        error('没有可用于统计的有效数据。');
    end
    statistics = struct( ...
        'mean', mean(validValues), ...
        'std', std(validValues, 0), ...
        'p95', nearestRankAbsoluteP95(validValues), ...
        'count', numel(validValues));
end


function p95Value = nearestRankAbsoluteP95(values)
% NEARESTRANKABSOLUTEP95 按绝对值升序的最近秩方法计算P95。

    validValues = values(isfinite(values));
    if isempty(validValues)
        p95Value = NaN;
        return;
    end
    sortedAbsoluteValues = sort(abs(validValues), 'ascend');
    percentileIndex = max(1, ceil(0.95 * numel(sortedAbsoluteValues)));
    p95Value = sortedAbsoluteValues(percentileIndex);
end


function printSummary(summary, rawStats, asfStats, correctionStats, ...
        preliminaryStats, differentialStats, aCsvFile, bCorrectionFile)
% PRINTSUMMARY 输出完整处理摘要。

    windowLabel = formatWindowLabel(summary.windowHours);
    fprintf('\n========== 最优%s差分处理摘要 ==========\n', ...
        windowLabel);
    fprintf('测试点：%s\n', summary.aStationName);
    fprintf('被测站点：%s\n', summary.bStationName);
    fprintf('测试点文件：%s\n', aCsvFile);
    fprintf('被测站点文件：%s\n', bCorrectionFile);
    fprintf('测试点允许插值的最大连续缺口：%d秒\n', ...
        summary.maximumAInterpolationGapSeconds);
    fprintf('是否触发自适应缺口处理：%s\n', ...
        yesNo(summary.adaptiveGapTriggered));
    fprintf('测试点全时段补齐缺秒：%d点\n', ...
        summary.aInterpolatedCountAll);
    fprintf('测试点全时段仍未补齐的长缺口点：%d点\n', ...
        summary.aUnresolvedMissingCountAll);
    fprintf('被测站点全时段补齐缺失分钟：%d分钟\n', ...
        summary.bFilledMinuteCountAll);
    fprintf('被测站点重复分钟（已取最后一条）：%d条\n', ...
        summary.bDuplicateMinuteCount);
    fprintf('有效整小时候选数：%d\n', summary.hourCandidateCount);
    fprintf('有效整分钟候选数：%d\n', summary.minuteCandidateCount);
    if isnan(summary.minimumHourP95)
        fprintf('整小时候选的最小绝对值P95：无有效整小时候选\n');
    else
        fprintf('整小时候选的最小绝对值P95：%.2f ns\n', ...
            summary.minimumHourP95);
    end
    fprintf('是否触发整分钟搜索：%s\n', yesNo(summary.minuteSearchTriggered));
    fprintf('最终窗口类型：%s\n', summary.selectionMode);
    fprintf('目标窗口长度：%s（%d点）\n', ...
        windowLabel, summary.windowPointCount);
    fprintf('名义时间范围：[ %s, %s )\n', ...
        char(string(summary.startTime, 'yyyy-MM-dd HH:mm:ss')), ...
        char(string(summary.nominalEndTime, 'yyyy-MM-dd HH:mm:ss')));
    fprintf('最后一个实际采样时刻：%s\n', ...
        char(string(summary.lastIncludedTime, 'yyyy-MM-dd HH:mm:ss')));
    fprintf('正式数据点数：%d\n', summary.pointCount);
    fprintf('所选窗口内测试点插值点：%d\n', ...
        summary.aInterpolatedCountSelected);
    fprintf('所选窗口及前置5分钟测试点插值点：%d（%.4f%%）\n', ...
        summary.aInterpolatedCountWithBaseline, ...
        summary.aInterpolationRatioWithBaselinePercent);
    fprintf('所选窗口及前置5分钟的最长插值缺口：%d秒\n', ...
        summary.aMaximumInterpolatedGapSecondsWithBaseline);
    fprintf('所选窗口内采用补齐改正数的秒级点数：%d\n', ...
        summary.bFilledSecondCountSelected);
    fprintf('自动计算ASF值：%.2f ns\n', summary.automaticAsfValue);
    fprintf('实际采用ASF值：%.2f ns（%s）\n', ...
        summary.asfValue, asfSourceText(summary.asfManualOverrideUsed));
    if summary.asfManualOverrideUsed
        fprintf('手动ASF相对自动值的改变量：%.2f ns\n', ...
            summary.asfDifferenceFromAutomatic);
    end
    fprintf('差分计算采用的A地前5分钟均值：%.2f ns\n', ...
        summary.aBaselineMean);
    fprintf('最终综合得分：%.2f ns\n', summary.score);
    printStatistics('测试点差分前时差', rawStats, false);
    printStatistics('ASF修正结果', asfStats, true);
    printStatistics('被测站点改正数', correctionStats, true);
    printStatistics('原始时延减改正数', preliminaryStats, true);
    printStatistics('最终差分结果', differentialStats, true);
    if differentialStats.p95 > summary.p95Threshold
        fprintf('[提示] 最终窗口绝对值P95仍超过%.2f ns。\n', ...
            summary.p95Threshold);
    end
    fprintf('============================================\n\n');
end


function printStatistics(dataName, statistics, showP95)
% PRINTSTATISTICS 在命令窗口输出统计量。

    fprintf('%s有效点数：%d\n', dataName, statistics.count);
    fprintf('%s均值：%.2f ns\n', dataName, statistics.mean);
    fprintf('%s样本标准差：%.2f ns\n', dataName, statistics.std);
    if showP95
        fprintf('%s绝对值95%%分位值：%.2f ns\n', ...
            dataName, statistics.p95);
    end
end


function createFullPreview(timeData, aRaw, bCorrection, ...
        aStationName, bStationName)
% CREATEFULLPREVIEW 显示全时段预览图，不保存。

    previewFigure = figure('Color', 'white', ...
        'Name', '全时段数据预览', 'NumberTitle', 'off', ...
        'Position', [60, 60, 1450, 850]);
    tiledlayout(previewFigure, 2, 1, 'TileSpacing', 'compact');

    axis1 = nexttile;
    plot(axis1, timeData, aRaw, 'LineWidth', 0.8);
    grid(axis1, 'on');
    box(axis1, 'on');
    title(axis1, sprintf('%s站原始时延全时段预览', aStationName), ...
        'Interpreter', 'none', 'FontName', 'Microsoft YaHei');
    ylabel(axis1, '时差(ns)', 'FontName', 'Microsoft YaHei');
    xtickformat(axis1, 'MM-dd HH:mm');
    applyStableScientificYAxis(axis1);

    axis2 = nexttile;
    plot(axis2, timeData, bCorrection, 'LineWidth', 0.8);
    grid(axis2, 'on');
    box(axis2, 'on');
    title(axis2, sprintf('%s站modelParam1全时段预览', bStationName), ...
        'Interpreter', 'none', 'FontName', 'Microsoft YaHei');
    xlabel(axis2, '时间', 'FontName', 'Microsoft YaHei');
    ylabel(axis2, '改正数(ns)', 'FontName', 'Microsoft YaHei');
    xtickformat(axis2, 'MM-dd HH:mm');
    applyStableScientificYAxis(axis2);
    drawnow;
end


function createSingleSeriesFigure(timeData, values, seriesName, ...
        plotTitle, statisticsText, outputFile, nominalEnd)
% CREATESINGLESERIESFIGURE 创建并保存单曲线图。

    figureHandle = figure('Color', 'white', ...
        'Name', plotTitle, 'NumberTitle', 'off', ...
        'Position', [100, 100, 1250, 740]);
    axisHandle = axes(figureHandle);
    pointIndex = (1:numel(values)).';
    plot(axisHandle, pointIndex, values, ...
        'LineWidth', 1.0, 'DisplayName', seriesName);
    formatPointPlot(figureHandle, axisHandle, plotTitle, ...
        numel(values), timeData(1), nominalEnd);
    text(axisHandle, 0.98, 0.97, statisticsText, ...
        'Units', 'normalized', ...
        'HorizontalAlignment', 'right', ...
        'VerticalAlignment', 'top', ...
        'FontName', 'Microsoft YaHei', 'FontSize', 10, ...
        'BackgroundColor', 'none', 'EdgeColor', 'none');
    saveHighResolutionFigure(figureHandle, char(outputFile));
end


function createMultiSeriesFigure(timeData, seriesValues, seriesNames, ...
        plotTitle, statisticsText, outputFile, nominalEnd)
% CREATEMULTISERIESFIGURE 创建并保存多曲线图。

    figureHandle = figure('Color', 'white', ...
        'Name', plotTitle, 'NumberTitle', 'off', ...
        'Position', [130, 80, 1250, 790]);
    axisHandle = axes(figureHandle);
    axisHandle.Position = [0.09, 0.22, 0.87, 0.70];
    pointIndex = (1:size(seriesValues, 1)).';
    hold(axisHandle, 'on');
    colors = lines(size(seriesValues, 2));
    for seriesIndex = 1:size(seriesValues, 2)
        plot(axisHandle, pointIndex, seriesValues(:, seriesIndex), ...
            'Color', colors(seriesIndex, :), 'LineWidth', 1.0, ...
            'DisplayName', seriesNames{seriesIndex});
    end
    hold(axisHandle, 'off');
    legend(axisHandle, 'Location', 'best', ...
        'FontName', 'Microsoft YaHei', 'Box', 'off');
    formatPointPlot(figureHandle, axisHandle, plotTitle, ...
        size(seriesValues, 1), timeData(1), nominalEnd);
    annotation(figureHandle, 'textbox', [0.06, 0.025, 0.90, 0.13], ...
        'String', statisticsText, ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle', ...
        'FontName', 'Microsoft YaHei', 'FontSize', 10, ...
        'BackgroundColor', 'none', 'EdgeColor', 'none', ...
        'FitBoxToText', 'off');
    saveHighResolutionFigure(figureHandle, char(outputFile));
end


function formatPointPlot(figureHandle, axisHandle, plotTitle, ...
        pointCount, actualStart, nominalEnd)
% FORMATPOINTPLOT 使用点序号作横坐标，并显示[start,end)名义时间。

    grid(axisHandle, 'on');
    box(axisHandle, 'on');
    title(axisHandle, plotTitle, 'Interpreter', 'none', ...
        'FontName', 'Microsoft YaHei', 'FontWeight', 'bold');
    timeRangeText = sprintf('%s——%s', ...
        char(string(actualStart, 'yyyy/MM/dd HH:mm:ss')), ...
        char(string(nominalEnd, 'yyyy/MM/dd HH:mm:ss')));
    xlabel(axisHandle, timeRangeText, ...
        'FontName', 'Microsoft YaHei', 'FontWeight', 'bold');
    ylabel(axisHandle, '时差(ns)', 'FontName', 'Microsoft YaHei');
    set(axisHandle, 'FontName', 'Microsoft YaHei', 'FontSize', 10);
    xlim(axisHandle, [0, max(1, pointCount)]);
    applyStableScientificXAxis(figureHandle, axisHandle);
    applyStableScientificYAxis(axisHandle);
end


function applyStableScientificXAxis(figureHandle, axisHandle)
% APPLYSTABLESCIENTIFICXAXIS 手动绘制横坐标指数，防止PNG导出丢失。

    drawnow;
    xLimits = xlim(axisHandle);
    xTicks = xticks(axisHandle);
    maximumMagnitude = max(abs([xLimits(:); xTicks(:)]));
    axisHandle.XAxis.Exponent = 0;
    if isempty(maximumMagnitude) || ~isfinite(maximumMagnitude) || ...
            maximumMagnitude == 0
        xticklabels(axisHandle, 'auto');
        return;
    end
    exponentValue = floor(log10(maximumMagnitude));
    if exponentValue < 3
        xticklabels(axisHandle, 'auto');
        return;
    end
    scaleFactor = 10 ^ exponentValue;
    xticklabels(axisHandle, compose('%.6g', xTicks / scaleFactor));

    axisPosition = axisHandle.Position;
    annotation(figureHandle, 'textbox', ...
        [axisPosition(1) + axisPosition(3) - 0.075, ...
         axisPosition(2) - 0.048, 0.075, 0.035], ...
        'String', sprintf('\\times10^{%d}', exponentValue), ...
        'HorizontalAlignment', 'right', ...
        'VerticalAlignment', 'middle', ...
        'FontName', 'Microsoft YaHei', 'FontSize', 10, ...
        'Interpreter', 'tex', ...
        'BackgroundColor', 'none', 'EdgeColor', 'none', ...
        'FitBoxToText', 'off');
end


function applyStableScientificYAxis(axisHandle)
% APPLYSTABLESCIENTIFICYAXIS 手动显示纵坐标指数。

    drawnow;
    yLimits = ylim(axisHandle);
    yTicks = yticks(axisHandle);
    maximumMagnitude = max(abs([yLimits(:); yTicks(:)]));
    axisHandle.YAxis.Exponent = 0;
    if isempty(maximumMagnitude) || ~isfinite(maximumMagnitude) || ...
            maximumMagnitude == 0
        yticklabels(axisHandle, 'auto');
        return;
    end
    exponentValue = floor(log10(maximumMagnitude));
    if exponentValue < 3 && exponentValue > -3
        yticklabels(axisHandle, 'auto');
        return;
    end
    scaleFactor = 10 ^ exponentValue;
    yticklabels(axisHandle, compose('%.6g', yTicks / scaleFactor));
    text(axisHandle, 0.01, 0.985, ...
        sprintf('\\times10^{%d}', exponentValue), ...
        'Units', 'normalized', ...
        'HorizontalAlignment', 'left', ...
        'VerticalAlignment', 'top', ...
        'FontName', 'Microsoft YaHei', 'FontSize', 10, ...
        'Interpreter', 'tex', 'BackgroundColor', 'white', ...
        'Margin', 1, 'Clipping', 'on');
end


function saveHighResolutionFigure(figureHandle, outputFile)
% SAVEHIGHRESOLUTIONFIGURE 以300 dpi保存PNG。

    drawnow;
    try
        exportgraphics(figureHandle, outputFile, 'Resolution', 300);
    catch
        print(figureHandle, outputFile, '-dpng', '-r300');
    end
end


function textValue = formatFullStatistics(statistics)
% FORMATFULLSTATISTICS 生成均值、标准差和P95图内文字。

    textValue = sprintf( ...
        '均值：%.2f ns\n标准差：%.2f ns\n95%%分位值：%.2f ns', ...
        statistics.mean, statistics.std, statistics.p95);
end


function textValue = formatAsfStatistics(statistics)
% FORMATASFSTATISTICS ASF结果的三项统计量均保留两位小数。

    textValue = sprintf( ...
        '均值：%.2f ns\n标准差：%.2f ns\n95%%分位值：%.2f ns', ...
        statistics.mean, statistics.std, statistics.p95);
end


function answer = yesNo(value)
    if value
        answer = '是';
    else
        answer = '否';
    end
end


function safeName = makeSafeFileName(stationName)
% MAKESAFEFILENAME 替换Windows文件名中的非法字符。

    safeName = regexprep(char(stationName), '[<>:"/\\|?*]', '_');
    safeName = regexprep(safeName, '[. ]+$', '');
    if isempty(safeName)
        error('站点名称中没有可用于文件名的有效字符。');
    end
end
