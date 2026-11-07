function [outputFile, summary] = ...
        filter_csv_by_3sigma_delay_correction_selectable_replace( ...
        inputFile, lowerLimit, upperLimit, dataVariableName, ...
        applyThreeSigma)
% FILTER_CSV_BY_3SIGMA_DELAY_CORRECTION_SELECTABLE_REPLACE
% 对原始时延CSV或差分改正数CSV进行人工粗限值筛选，并可选单轮3sigma。
%
% 直接运行：
%   filter_csv_by_3sigma_delay_correction_selectable
%
% 批处理调用（不显示图形或对话框）：
%   [outputFile, summary] = ...
%       filter_csv_by_3sigma_delay_correction_selectable( ...
%       inputFile, lowerLimit, upperLimit);
%   第5个参数applyThreeSigma可设为true或false；省略时默认为true。
%
% 支持的两种数据格式：
%   1. 原始时延文件：必须包含 time、differentialDelay；
%   2. 改正数文件：必须包含 time、modelParam1。
%
% 处理规则：
%   1. 根据字段名自动识别文件格式和待处理数据列；
%   2. 先删除非有限值以及人工上下限以外的数据所在整行；
%   3. 由用户选择是否继续进行3sigma处理；
%   4. 若选择进行，则使用粗大值删除后的数据计算均值和样本标准差，
%      按 abs(数据-均值) > 3×标准差进行一轮判断；
%   5. 若选择不进行，则只删除粗大值和无效值所在整行；
%   6. 保留剩余行的全部原始字段、字段顺序、时间和值；
%   7. 下限或上限留空表示不限制该方向。

    %% 0. 初始化
    outputFile = "";
    summary = struct();
    programFolder = fileparts(mfilename('fullpath'));
    if isempty(programFolder)
        programFolder = pwd;
    end

    if nargin < 1 || isempty(inputFile)
        [fileName, filePath] = uigetfile( ...
            {'*.csv', 'CSV数据文件 (*.csv)'}, ...
            '请选择原始时延或差分改正数CSV文件', programFolder);
        if isequal(fileName, 0)
            fprintf('未选择CSV文件，程序已结束。\n');
            return;
        end
        inputFile = fullfile(filePath, fileName);
    else
        inputFile = char(string(inputFile));
        [filePath, baseName, extension] = fileparts(inputFile);
        fileName = [baseName, extension];
    end
    if ~isfile(inputFile)
        error('所选CSV文件不存在：%s', inputFile);
    end

    limitsProvided = nargin >= 3 && ~isempty(lowerLimit) && ...
        ~isempty(upperLimit);
    if nargin < 4
        dataVariableName = "";
    else
        dataVariableName = string(dataVariableName);
    end
    if nargin < 5
        applyThreeSigma = [];
    end

    %% 1. 一次读取并自动识别文件类型
    fprintf('正在读取CSV并识别格式……\n');
    readTimer = tic;
    [sourceTable, usedEncoding] = readSupportedCsv(inputFile);
    fprintf('读取完成：%d行，编码%s，耗时%.3f秒。\n', ...
        height(sourceTable), usedEncoding, toc(readTimer));
    if isempty(sourceTable)
        error('所选CSV中没有数据行。');
    end

    [dataVariableName, dataDisplayName, fileType] = ...
        chooseDataVariable(sourceTable, dataVariableName, limitsProvided);
    dataValues = double(sourceTable.(char(dataVariableName)));
    invalidRowMask = ~isfinite(dataValues);
    validRowMask = ~invalidRowMask;
    if ~any(validRowMask)
        error('%s列中没有可用于3sigma计算的有效数值。', ...
            dataVariableName);
    end
    fprintf('已识别为%s，处理列：%s。\n', fileType, dataVariableName);

    %% 2. 交互运行时预览数据并设置人工上下限
    if ~limitsProvided
        showPreview(dataValues, validRowMask, dataDisplayName, fileType);
        limitAnswers = inputdlg( ...
            {sprintf('%s下限（留空表示不限制）：', dataDisplayName), ...
             sprintf('%s上限（留空表示不限制）：', dataDisplayName)}, ...
            '设置粗大值上下限（单位：ns）', [1, 58], {'', ''});
        if isempty(limitAnswers)
            fprintf('未设置粗大值范围，程序已结束。\n');
            return;
        end
        lowerLimit = parseOptionalLimit( ...
            limitAnswers{1}, -Inf, [dataDisplayName, '下限']);
        upperLimit = parseOptionalLimit( ...
            limitAnswers{2}, Inf, [dataDisplayName, '上限']);
    else
        lowerLimit = parseOptionalLimit( ...
            lowerLimit, -Inf, [dataDisplayName, '下限']);
        upperLimit = parseOptionalLimit( ...
            upperLimit, Inf, [dataDisplayName, '上限']);
    end
    checkLimitOrder(lowerLimit, upperLimit, dataDisplayName);

    %% 3. 先按人工范围删除粗大值所在整行
    grossRowMask = validRowMask & ...
        (dataValues < lowerLimit | dataValues > upperLimit);
    afterGrossValidMask = validRowMask & ~grossRowMask;

    grossHandling = questdlg('粗大值如何处理？', '选择粗大值处理方式', ...
        '剔除', '替代', '取消', '剔除');
    if isempty(grossHandling) || strcmp(grossHandling, '取消')
        fprintf('用户取消处理，未生成输出文件。\n');
        return;
    end
    replacementWindowMinutes = NaN;
    replacedValues = dataValues;
    if strcmp(grossHandling, '替代')
        replacementAnswer = inputdlg({'起始均值窗口长度（分钟）：'}, ...
            '设置粗大值替代均值窗口', [1, 42], {'1'});
        if isempty(replacementAnswer)
            fprintf('未设置替代均值窗口，程序已结束。\n');
            return;
        end
        replacementWindowMinutes = str2double(strtrim(string(replacementAnswer{1})));
        if ~isscalar(replacementWindowMinutes) || ~isfinite(replacementWindowMinutes) || ...
                replacementWindowMinutes <= 0
            error('替代均值窗口必须是大于0的数值（分钟）。');
        end
        [replacedValues, replacementMean, replacementWindowUsed] = ...
            replaceGrossValues(sourceTable, dataValues, grossRowMask, ...
            replacementWindowMinutes);
        if ~isfinite(replacementMean)
            error('起始均值窗口向后移动5次后仍没有有限正常数据，无法替代粗大值。');
        end
        fprintf('粗大值已用起始%.4g分钟窗口均值%.6f ns替代。\n', ...
            replacementWindowUsed, replacementMean);
    elseif ~any(afterGrossValidMask)
        error('粗大值删除后没有剩余有效数据，未生成输出文件。');
    end

    %% 4. 选择是否执行3sigma，并按选择处理
    if isempty(applyThreeSigma)
        if limitsProvided
            applyThreeSigma = true;
        else
            sigmaChoice = questdlg( ...
                ['粗大值已按所设范围识别。是否继续使用剩余数据' ...
                 '进行一轮3sigma异常值剔除？'], ...
                '选择处理方式', '进行3sigma', ...
                '仅剔除粗大值', '取消', '进行3sigma');
            if isempty(sigmaChoice) || strcmp(sigmaChoice, '取消')
                fprintf('用户取消处理，未生成输出文件。\n');
                return;
            end
            applyThreeSigma = strcmp(sigmaChoice, '进行3sigma');
        end
    else
        applyThreeSigma = validateLogicalScalar( ...
            applyThreeSigma, 'applyThreeSigma');
    end

    if applyThreeSigma
        sigmaMask = validRowMask;
        if strcmp(grossHandling, '剔除')
            sigmaMask = afterGrossValidMask;
        end
        [threeSigmaRowMask, meanValue, stdValue] = ...
            calculateThreeSigmaMask(replacedValues, sigmaMask);
        if strcmp(grossHandling, '替代')
            outputSuffix = '_粗大值替代及3sigma异常值剔除.csv';
        else
            outputSuffix = '_粗大值及3sigma异常值剔除.csv';
        end
    else
        threeSigmaRowMask = false(size(dataValues));
        meanValue = NaN;
        stdValue = NaN;
        outputSuffix = '_粗大值剔除.csv';
    end
    deleteRowMask = invalidRowMask | threeSigmaRowMask;
    if strcmp(grossHandling, '剔除')
        deleteRowMask = deleteRowMask | grossRowMask;
    else
        sourceTable.(char(dataVariableName)) = replacedValues;
    end
    filteredTable = sourceTable(~deleteRowMask, :);
    if isempty(filteredTable)
        error('筛选后没有剩余数据，未生成输出文件。');
    end

    %% 5. 保存全部原始字段和剩余行
    [~, baseName, ~] = fileparts(fileName);
    outputFile = string(fullfile(filePath, [baseName, outputSuffix]));
    try
        writetable(filteredTable, char(outputFile), ...
            'FileType', 'text', 'Delimiter', ',', ...
            'Encoding', usedEncoding);
    catch ME
        error('保存筛选结果失败：%s', ME.message);
    end

    %% 6. 汇总
    summary = struct( ...
        'inputFile', string(inputFile), ...
        'outputFile', outputFile, ...
        'fileType', fileType, ...
        'dataVariableName', dataVariableName, ...
        'dataDisplayName', dataDisplayName, ...
        'encoding', string(usedEncoding), ...
        'lowerLimit', lowerLimit, ...
        'upperLimit', upperLimit, ...
        'grossHandling', string(grossHandling), ...
        'replacementWindowMinutes', replacementWindowMinutes, ...
        'threeSigmaApplied', logical(applyThreeSigma), ...
        'originalRowCount', height(sourceTable), ...
        'invalidRowCount', sum(invalidRowMask), ...
        'grossRowCount', sum(grossRowMask), ...
        'threeSigmaRowCount', sum(threeSigmaRowMask), ...
        'totalDeletedRowCount', sum(deleteRowMask), ...
        'remainingRowCount', height(filteredTable), ...
        'meanAfterGrossRemoval', meanValue, ...
        'stdAfterGrossRemoval', stdValue);

    if applyThreeSigma
        fprintf('\nCSV粗大值及3sigma处理完成。\n');
    else
        fprintf('\nCSV粗大值剔除完成，未进行3sigma处理。\n');
    end
    fprintf('文件类型：%s\n', fileType);
    fprintf('处理字段：%s（%s）\n', dataDisplayName, dataVariableName);
    fprintf('输入文件：%s\n', inputFile);
    fprintf('识别编码：%s\n', usedEncoding);
    fprintf('原始数据行数：%d\n', summary.originalRowCount);
    fprintf('无效数据行数：%d\n', summary.invalidRowCount);
    fprintf('粗大值范围：[%s, %s] ns\n', ...
        formatLimitValue(lowerLimit), formatLimitValue(upperLimit));
    fprintf('粗大值阶段删除行数：%d\n', summary.grossRowCount);
    if applyThreeSigma
        fprintf('参与3sigma计算行数：%d\n', sum(afterGrossValidMask));
        fprintf('均值：%.4f ns\n', meanValue);
        fprintf('样本标准差：%.4f ns\n', stdValue);
        fprintf('3sigma异常行数：%d\n', summary.threeSigmaRowCount);
    else
        fprintf('3sigma处理：未执行\n');
    end
    fprintf('最终删除行数：%d\n', summary.totalDeletedRowCount);
    fprintf('处理后剩余行数：%d\n', summary.remainingRowCount);
    fprintf('输出文件：%s\n\n', outputFile);
end

function [values, replacementMean, windowUsed] = replaceGrossValues( ...
        sourceTable, values, grossMask, windowMinutes)
    timeText = strtrim(string(sourceTable.time));
    parsedTime = NaT(height(sourceTable), 1);
    formats = {'yyyy-MM-dd HH:mm:ss', 'MM/dd/yyyy HH:mm:ss'};
    for formatIndex = 1:numel(formats)
        pending = find(isnat(parsedTime) & strlength(timeText) > 0);
        if isempty(pending), break; end
        try
            parsed = datetime(timeText(pending), 'InputFormat', formats{formatIndex});
            parsedTime(pending(~isnat(parsed))) = parsed(~isnat(parsed));
        catch
        end
    end
    if all(isnat(parsedTime))
        error('无法解析time字段，不能按起始时间窗口计算替代均值。');
    end
    firstTime = parsedTime(find(~isnat(parsedTime), 1));
    replacementMean = NaN;
    windowUsed = windowMinutes;
    for shiftIndex = 0:4
        windowStart = firstTime + minutes(shiftIndex * windowMinutes);
        windowEnd = windowStart + minutes(windowMinutes);
        normalMask = isfinite(values) & ~grossMask & ...
            ~isnat(parsedTime) & parsedTime >= windowStart & parsedTime < windowEnd;
        if any(normalMask)
            replacementMean = mean(values(normalMask));
            windowUsed = (shiftIndex + 1) * windowMinutes;
            values(grossMask) = replacementMean;
            return;
        end
    end
end


function [sourceTable, usedEncoding] = readSupportedCsv(inputFile)
% READSUPPORTEDCSV 识别文本编码，并按现有两类CSV字段读取。

    usedEncoding = detectTextEncoding(inputFile);
    try
        importOptions = detectImportOptions(inputFile, ...
            'FileType', 'text', 'Delimiter', ',', ...
            'Encoding', usedEncoding, ...
            'VariableNamingRule', 'preserve');
        variableNames = string(importOptions.VariableNames);
        if ~any(variableNames == "time")
            error('CSV缺少必需字段time。');
        end
        if ~any(variableNames == "differentialDelay") && ...
                ~any(variableNames == "modelParam1")
            error(['CSV必须包含原始时延字段differentialDelay，' ...
                '或改正数字段modelParam1。']);
        end
        importOptions = setvartype(importOptions, 'time', 'string');
        numericTargets = intersect( ...
            {'differentialDelay', 'modelParam1'}, ...
            importOptions.VariableNames, 'stable');
        importOptions = setvartype(importOptions, numericTargets, 'double');
        sourceTable = readtable(inputFile, importOptions);
    catch ME
        error('无法读取所选CSV：%s', ME.message);
    end
end


function encodingName = detectTextEncoding(inputFile)
% DETECTTEXTENCODING 通过BOM和UTF-8字节合法性区分UTF-8与GBK。

    fileId = fopen(inputFile, 'rb');
    if fileId < 0
        error('无法打开CSV文件：%s', inputFile);
    end
    cleanupObject = onCleanup(@() fclose(fileId));
    sampleBytes = fread(fileId, 1024 * 1024, '*uint8').';
    lastCompleteLine = find(sampleBytes == 10, 1, 'last');
    if ~isempty(lastCompleteLine)
        sampleBytes = sampleBytes(1:lastCompleteLine);
    end
    if numel(sampleBytes) >= 3 && ...
            isequal(sampleBytes(1:3), uint8([239, 187, 191]))
        encodingName = 'UTF-8';
    elseif isValidUtf8(sampleBytes)
        encodingName = 'UTF-8';
    else
        encodingName = 'GBK';
    end
end


function valid = isValidUtf8(bytes)
% ISVALIDUTF8 严格检查字节序列是否符合UTF-8编码。

    valid = true;
    byteCount = numel(bytes);
    position = 1;
    while position <= byteCount
        firstByte = double(bytes(position));
        if firstByte <= 127
            position = position + 1;
            continue;
        end
        if firstByte >= 194 && firstByte <= 223
            if position + 1 > byteCount || ...
                    ~isContinuationByte(bytes(position + 1))
                valid = false;
                return;
            end
            position = position + 2;
        elseif firstByte == 224
            if position + 2 > byteCount || ...
                    ~isByteInRange(bytes(position + 1), 160, 191) || ...
                    ~isContinuationByte(bytes(position + 2))
                valid = false;
                return;
            end
            position = position + 3;
        elseif (firstByte >= 225 && firstByte <= 236) || ...
                (firstByte >= 238 && firstByte <= 239)
            if position + 2 > byteCount || ...
                    ~isContinuationByte(bytes(position + 1)) || ...
                    ~isContinuationByte(bytes(position + 2))
                valid = false;
                return;
            end
            position = position + 3;
        elseif firstByte == 237
            if position + 2 > byteCount || ...
                    ~isByteInRange(bytes(position + 1), 128, 159) || ...
                    ~isContinuationByte(bytes(position + 2))
                valid = false;
                return;
            end
            position = position + 3;
        elseif firstByte == 240
            if position + 3 > byteCount || ...
                    ~isByteInRange(bytes(position + 1), 144, 191) || ...
                    ~isContinuationByte(bytes(position + 2)) || ...
                    ~isContinuationByte(bytes(position + 3))
                valid = false;
                return;
            end
            position = position + 4;
        elseif firstByte >= 241 && firstByte <= 243
            if position + 3 > byteCount || ...
                    ~isContinuationByte(bytes(position + 1)) || ...
                    ~isContinuationByte(bytes(position + 2)) || ...
                    ~isContinuationByte(bytes(position + 3))
                valid = false;
                return;
            end
            position = position + 4;
        elseif firstByte == 244
            if position + 3 > byteCount || ...
                    ~isByteInRange(bytes(position + 1), 128, 143) || ...
                    ~isContinuationByte(bytes(position + 2)) || ...
                    ~isContinuationByte(bytes(position + 3))
                valid = false;
                return;
            end
            position = position + 4;
        else
            valid = false;
            return;
        end
    end
end


function result = isContinuationByte(byteValue)
    result = isByteInRange(byteValue, 128, 191);
end


function result = isByteInRange(byteValue, lowerBound, upperBound)
    numericByte = double(byteValue);
    result = numericByte >= lowerBound && numericByte <= upperBound;
end


function [variableName, displayName, fileType] = ...
        chooseDataVariable(sourceTable, requestedName, noninteractiveMode)
% CHOOSEDATAVARIABLE 根据字段自动识别；极少数双字段文件允许人工选择。

    tableNames = string(sourceTable.Properties.VariableNames);
    supportedNames = ["differentialDelay", "modelParam1"];
    supportedDisplayNames = ["原始时延", "差分改正数"];
    supportedFileTypes = ["原始时延数据文件", "差分改正数文件"];
    availableMask = ismember(supportedNames, tableNames);
    availableNames = supportedNames(availableMask);
    availableDisplays = supportedDisplayNames(availableMask);
    availableTypes = supportedFileTypes(availableMask);

    if strlength(requestedName) > 0
        matchPosition = find(availableNames == requestedName, 1);
        if isempty(matchPosition)
            error('指定字段%s不存在，或不是支持的数据字段。', requestedName);
        end
    elseif isscalar(availableNames)
        matchPosition = 1;
    elseif noninteractiveMode
        error(['文件同时包含differentialDelay和modelParam1，' ...
            '批处理调用时请用第4个参数指定待处理字段。']);
    else
        listItems = cellstr(availableDisplays + "（" + availableNames + "）");
        [matchPosition, confirmed] = listdlg( ...
            'ListString', listItems, ...
            'PromptString', '文件包含两个支持字段，请选择待处理项：', ...
            'SelectionMode', 'single', 'InitialValue', 1, ...
            'Name', '选择处理字段', 'ListSize', [380, 100]);
        if ~confirmed
            error('未选择待处理字段，程序已结束。');
        end
    end

    variableName = availableNames(matchPosition);
    displayName = availableDisplays(matchPosition);
    fileType = availableTypes(matchPosition);
end


function showPreview(values, validRowMask, displayName, fileType)
% SHOWPREVIEW 显示待处理字段的全时段预览。

    pointIndex = (1:numel(values)).';
    previewFigure = figure('Color', 'white', ...
        'Name', '粗大值范围设置预览', 'NumberTitle', 'off', ...
        'Position', [80, 80, 1450, 760]);
    previewAxes = axes(previewFigure);
    plot(previewAxes, pointIndex(validRowMask), values(validRowMask), ...
        '.', 'Color', [0.0000, 0.4470, 0.7410], 'MarkerSize', 3);
    grid(previewAxes, 'on');
    box(previewAxes, 'on');
    title(previewAxes, sprintf('%s：%s预览', fileType, displayName), ...
        'Interpreter', 'none', 'FontName', 'Microsoft YaHei', ...
        'FontWeight', 'bold');
    xlabel(previewAxes, '数据点序号', 'FontName', 'Microsoft YaHei');
    ylabel(previewAxes, sprintf('%s(ns)', displayName), ...
        'FontName', 'Microsoft YaHei');
    set(previewAxes, 'FontName', 'Microsoft YaHei', 'FontSize', 10);
    if numel(values) > 1
        xlim(previewAxes, [1, numel(values)]);
    else
        xlim(previewAxes, [0.5, 1.5]);
    end
    drawnow;
end


function limitValue = parseOptionalLimit(rawValue, defaultValue, fieldName)
% PARSEOPTIONALLIMIT 解析数值或人工输入；空值表示不限制。

    if isnumeric(rawValue)
        if isscalar(rawValue) && ~isnan(rawValue)
            limitValue = double(rawValue);
            return;
        end
        error('%s必须是单个有效数值。', fieldName);
    end

    cleanText = strtrim(string(rawValue));
    if strlength(cleanText) == 0
        limitValue = defaultValue;
        return;
    end
    limitValue = str2double(cleanText);
    if numel(limitValue) ~= 1 || isnan(limitValue)
        error('%s必须是有效数值，或者留空表示不限制。', fieldName);
    end
end


function logicalValue = validateLogicalScalar(rawValue, fieldName)
% VALIDATELOGICALSCALAR 校验批处理模式下的逻辑开关。

    if (islogical(rawValue) || isnumeric(rawValue)) && ...
            isscalar(rawValue) && isfinite(double(rawValue)) && ...
            any(double(rawValue) == [0, 1])
        logicalValue = logical(rawValue);
        return;
    end
    error('%s必须是逻辑值true或false。', fieldName);
end


function checkLimitOrder(lowerLimit, upperLimit, dataName)
% CHECKLIMITORDER 检查下限不能大于上限。

    if lowerLimit > upperLimit
        error('%s的下限不能大于上限。', dataName);
    end
end


function textValue = formatLimitValue(limitValue)
% FORMATLIMITVALUE 将无穷边界显示为“不限制”。

    if isinf(limitValue)
        textValue = '不限制';
    else
        textValue = sprintf('%.4f', limitValue);
    end
end


function [abnormalMask, meanValue, stdValue] = ...
        calculateThreeSigmaMask(values, validRowMask)
% CALCULATETHREESIGMAMASK 使用粗大值删除后的数据执行一次3sigma。

    validValues = values(validRowMask);
    meanValue = mean(validValues);
    stdValue = std(validValues, 0);
    abnormalMask = false(size(values));
    if isfinite(stdValue) && stdValue > 0
        abnormalMask(validRowMask) = ...
            abs(validValues - meanValue) > 3 * stdValue;
    end
end
