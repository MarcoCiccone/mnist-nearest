local torch = require('torch')
local nn = require('nn')
local nngraph = require('nngraph')
local hdf5 = require('hdf5')
local nntrainer = require('nntrainer')
local utils = require('utils')
local table_utils = require('table_utils')
local logger = require('logger')()

torch.manualSeed(2)
torch.setdefaulttensortype('torch.FloatTensor')
torch.setnumthreads(4)

-- Hyper-parameters
wordLength = 55
vocabSize = 9739
numImages = 123287
imgFeatLength = 4096
wordVecLength = 500
numClasses = 431
txtEmbeddingInitRange = 1.0
answerInitRange = 0.01
momentum = 0.9
dropoutRate = 0.5

learningRates = {
    txtEmbedding = 0.8,
    answer = 0.1
}
weightDecays = {
    txtEmbedding = 0.0,
    answer = 0.00005
}
gradClips = {
    txtEmbedding = 0.1,
    answer = 0.1
}

-- Model architecture
function createModel()
    local input = nn.Identity()()
    -- (B, 4151) -> (B, 4096)
    local imgSel = nn.Narrow(2, 1, imgFeatLength)(input)
    -- (B, 56) -> (B, 55)
    local txtSel = nn.Narrow(2, imgFeatLength + 1, wordLength)(input)
    -- (B, 55) -> (B, 55, 500)
    local txtEmbeddingLayer = nn.LookupTable(vocabSize, wordVecLength)
    txtEmbeddingLayer.weight:copy(
        torch.rand(vocabSize, wordVecLength) * 
        txtEmbeddingInitRange - txtEmbeddingInitRange / 2)
    txtEmbedding = txtEmbeddingLayer(txtSel)
    -- (B, 55, 500) -> (B, 500)
    local bowLayer = nn.Sum(2)
    local bow = bowLayer(txtEmbedding)
    -- (B, 4096) + (B, 500) -> (B, 4596)
    local imgtxtConcat = nn.JoinTable(2, 2)({bow, imgSel})

    local dropout
    if dropoutRate > 0.0 then
        local dropoutLayer = nn.Dropout(dropoutRate)
        dropout = dropoutLayer(imgtxtConcat)
    else
        dropout = imgtxtConcat
    end
    -- (B, 4596) -> (B, 431)
    local answerLayer = nn.Linear(imgFeatLength + wordVecLength, numClasses)
    answerLayer.weight:copy(
        torch.rand(imgFeatLength + wordVecLength, numClasses) * 
        answerInitRange - answerInitRange / 2)
    answerLayer.bias:copy(torch.rand(numClasses) * 
        answerInitRange - answerInitRange / 2)
    local answer = answerLayer(dropout)
    local model = nn.gModule({input}, {answer})
    model.parameterMap = utils.getParameterMap({
        txtEmbedding = txtEmbeddingLayer,
        answer = answerLayer})
    model.sliceLayer = utils.sliceLayer(model.parameterMap)
    return model
end

-- Command line options
local cmd = torch.CmdLine()
cmd:text()
cmd:text('ImageQA IMG+BOW Training')
cmd:text()
cmd:text('Options:')
cmd:option('-train', false, 'whether to train a new network')
cmd:option('-path', 'imageqa_img_bow.w', 'save network path')
cmd:option('-save', false, 'whether to save the trained network')
cmd:option('-gpu', false, 'whether to run on GPU')
cmd:text()
opt = cmd:parse(arg)

if opt.gpu then
    require('cutorch')
    require('cunn')
end

-- Load data
logger:logInfo('Loading dataset')
local dataPath = '../../data/cocoqa-nearest/all_id_unk.h5'
local data = hdf5.open(dataPath, 'r'):all()

logger:logInfo('Loading image feature')
local dataImgPath = '../../data/cocoqa-nearest/img_feat.h5'
local dataImg = hdf5.open(dataImgPath, 'r'):all()

data.trainData = data.trainData[{{}, {2, 56}}]:float()
data.validData = data.validData[{{}, {2, 56}}]:float()
data.testData = data.testData[{{}, {2, 56}}]:float()

data.trainData = torch.cat(dataImg.train, data.trainData, 2)
data.validData = torch.cat(dataImg.valid, data.validData, 2)
data.testData = torch.cat(dataImg.test, data.testData, 2)

data.allData = torch.cat(data.trainData, data.validData, 1)
data.allLabel = torch.cat(data.trainLabel, data.validLabel, 1)

logger:logInfo('Creating model')
local model = createModel()

model.criterion = nn.CrossEntropyCriterion()
model.decision = function(prediction)
    local score, idx = prediction:max(2)
    return idx
end

local loopConfig = {
    numEpoch = 200,
    trainBatchSize = 64,
    evalBatchSize = 1000
}

-- Construct optimizer configs
local w, dl_dw = model:getParameters()
local optimConfig = {
    learningRate = 1.0,
    momentum = momentum,
    learningRates = utils.fillVector(
        torch.Tensor(w:size()), model.sliceLayer, learningRates),
    weightDecay = 0.0,
    weightDecays = utils.fillVector(
        torch.Tensor(w:size()), model.sliceLayer, weightDecays),
    gradientClip = utils.gradientClip(gradClips, model.sliceLayer)
}

local optimizer = optim.sgd
logger:logInfo('Start training')

local trainer = NNTrainer(model, loopConfig, optimizer, optimConfig)
trainer:trainLoop(data.allData, data.allLabel, data.testData, data.testLabel)

local evaluator = NNEvaluator(model)
local loss, rate = evaluator:evaluate(data.testData, data.testLabel, 100)
logger:logInfo(string.format('Accuracy: %.4f', rate))
