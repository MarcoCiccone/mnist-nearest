local mynn = require('mynn')
local BatchReshape, parent = torch.class('mynn.BatchReshape', 'nn.Module')

function BatchReshape:__init(...)
   parent.__init(self)
   local arg = {...}

   self.size = torch.LongStorage()
   self.batchsize = torch.LongStorage()
   self.numel = 1
   if torch.type(arg[#arg]) == 'boolean' then
      self.batchMode = arg[#arg]
      table.remove(arg, #arg)
   end
   local n = #arg
   if n == 1 and torch.typename(arg[1]) == 'torch.LongStorage' then
      self.size:resize(#arg[1]):copy(arg[1])
   else
      self.size:resize(n)
      for i=1,n do
         self.size[i] = arg[i]
      end
   end

   self.nelement = 1
   self.batchsize:resize(#self.size+1)
   for i=1,#self.size do
      self.nelement = self.nelement * self.size[i]
      self.batchsize[i+1] = self.size[i]
   end

   for i = 1, #self.size do
      self.numel = self.numel * self.size[i]
   end
   
   -- only used for non-contiguous input or gradOutput
   self._input = torch.Tensor()
   self._gradOutput = torch.Tensor()
end

function BatchReshape:updateOutput(input)
   -- print('BatchReshape forward')
   -- if self.name then
      -- print(self.name)
   -- end
   -- print(input:size())
   if not input:isContiguous() then
      self._input:resizeAs(input)
      self._input:copy(input)
      input = self._input
   end
   
   if (self.batchMode == false) or (
         (self.batchMode == nil) and 
         (input:nElement() == self.nelement and input:size(1) ~= 1)
      ) then
      self.output:view(input, self.size)
   else
      self.batchsize[1] = input:numel() / self.numel
      self.output:view(input, self.batchsize)
   end
   -- print(self.output:size())
   return self.output
end

function BatchReshape:updateGradInput(input, gradOutput)
   -- print('BatchReshape backward')
   -- if self.name then
   --    print(self.name)
   -- end
   -- print(input:size())
   -- print(gradOutput:size())
   if not gradOutput:isContiguous() then
      self._gradOutput:resizeAs(gradOutput)
      self._gradOutput:copy(gradOutput)
      gradOutput = self._gradOutput
   end
   
   self.gradInput:viewAs(gradOutput, input)
   return self.gradInput
end


function BatchReshape:__tostring__()
  return torch.type(self) .. '(' ..
      table.concat(self.size:totable(), 'x') .. ')'
end
