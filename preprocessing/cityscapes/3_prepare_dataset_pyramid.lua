paths.dofile('../../dataset_helper.lua')
local gm = require 'graphicsmagick'
require 'image'

local class_info, class_color_map, num_classes = paths.dofile('class_colors.lua')

--vgg_rgb_mean = {123.68, 116.779, 103.939}
local num_classes = 19
--local baseline = 0.5372
-- orig: 1241x376

--local img_sizes = {{1248, 384}, {1056, 320}, {880, 272}, {736, 224}, {624, 192}, {528, 160},
--                   {448, 144}, {368, 112}, {320, 96}}
--local img_sizes = {{1248, 384}, {1056, 320}, {880, 272}, {736, 224}, {624, 192}, {528, 160},
--                   {448, 144}, {368, 112}, {320, 96}}


local img_sizes = {{1504,672}, {1152,512}, {896,400}, {688,304}, {528,240}, {400,176}, {304,128},
                   {240,112}}
local orig_width = 1952
local orig_height = 864

--local img_sizes = ComputePyramidResolutions(2048, 1024, 1.3, 8)
--local orig_width = 2048
--local orig_height = 1024

-- subsampling scale of network
--local net_s_factor = 16
local net_s_factor = 8
--local net_s_factor = 4
-- scale at whitch the pyramid is concatenated
local target_scale = net_s_factor
--local target_scale = 8
--local target_scale = 16
--local target_scale = 4
net_out_sizes = {}
for i = 1, #img_sizes do
  table.insert(net_out_sizes, {img_sizes[i][1] / net_s_factor, img_sizes[i][2] / net_s_factor})
end
print(net_out_sizes)

--local colors = {{255,0,0}, {}}
color_coding = {{0,0,0}, {128,64,128}, {244,35,232}, {70,70,70}, {102,102,156}, {190,153,153},
                {153,153,153}, {250,170,30}, {220,220,0}}

downsample_factors = {}
for i = 1, #img_sizes do
  table.insert(downsample_factors, img_sizes[1][1] / img_sizes[i][1])
end
print(downsample_factors)

--local scale_size = 4
--local scale_size = 6
--local scale_size = 3
--local scale_size = 12
-- size of the VGG receptive field
rf_size = 186
--scales = {3, 6, 9}
--scales = {2, 6, 9}
--scales = {2, 6}

-- 3 scale ex
scales = {1, 4, 7}

first_width = img_sizes[1][1]
first_height = img_sizes[1][2]
target_width = img_sizes[1][1] / target_scale
target_height = img_sizes[1][2] / target_scale
disp_scale = first_width / orig_width
print('Target size = ' .. target_width .. 'x' .. target_height)
print('Disp scale = ' .. disp_scale)

--local correct_width = 1632
--local correct_height = 736

--local root_dir = '/mnt/ikreso/datasets/Cityscapes/'
local root_dir = '/home/kivan/datasets/Cityscapes/'
--local rgb_dir = root_dir .. '/1952x864/img/data/'
--local gt_dir = root_dir .. '/1952x864/img/labels/'
--local depth_dir = root_dir .. '/1952x864/img/depth/'
local img_dir = orig_width .. 'x' .. orig_height
local rgb_dir = root_dir .. img_dir .. '/img/data/'
local gt_dir = root_dir .. img_dir .. '/img/labels/'
local depth_dir = root_dir .. img_dir .. '/img/depth/'
--local gt_dir = root_dir .. '/1952x864/img/labels/'
--local depth_dir = root_dir .. '/1952x864/img/depth/'
local out_dir = root_dir .. '/pyramid/' .. first_width .. 'x' .. first_height .. '_baseline/'
--local out_dir = root_dir .. '/pyramid/' .. first_width .. 'x' .. first_height .. '_' ..
--                net_s_factor .. 's/'
                --net_s_factor .. 's_1scale/'
local debug_dir = out_dir .. '/debug/'

os.execute("mkdir -p " .. out_dir)
os.execute("mkdir -p " .. debug_dir)

local function PrepareDataset(name, max_in_file, has_gt)
  local rgb_subdir = rgb_dir .. name
  local gt_subdir = gt_dir .. name
  local save_dir = out_dir .. '/' .. name .. '/'
  local save_debug = save_dir .. '/debug/'
  os.execute('mkdir -p ' .. save_dir)
  os.execute('mkdir -p ' .. save_debug)
  local file_num = 1
  local data = {}
  local depth = {}
  local labels = {}
  local filenames = {}
  local img_list = torch.load(root_dir .. name .. '_img_list.t7', img_list)

  local idx_shuffle = torch.randperm(#img_list)

  for i = 1, idx_shuffle:size(1) do
    local idx = idx_shuffle[i]
    local img_path = name .. '/' .. img_list[idx][2]
    xlua.progress(i, idx_shuffle:size(1))

    --table.insert(data, norm_img:view(num_channels, img_height, img_width))
    ----table.insert(labels, label_img:view(img_height, img_width))
    --table.insert(labels, {label_img:view(img_height, img_width), class_weights})

    local img = gm.Image(rgb_dir .. img_path)
    local gt_img, scaled_gt_img, label_img, class_weights
    if has_gt then
      gt_img = image.load(gt_dir .. img_path, 3, 'byte')
      scaled_gt_img = image.scale(gt_img, first_width, first_height, "simple")
      label_img = torch.IntTensor(first_height, first_width)
      class_weights = ConvertLabelFormat(scaled_gt_img, class_color_map, num_classes, label_img)
      table.insert(labels, {label_img:view(1, first_height, first_width), class_weights})
    end
    local depth_img = gm.Image(depth_dir .. img_path)
    depth_img:size(target_width, target_height)
    depth_img = depth_img:toTensor('byte','RGB','DHW'):float()[1]
    depth_img:mul(disp_scale)
    local norm_depth = (depth_img - depth_img:mean()) / depth_img:std()
    table.insert(depth, {norm_depth, depth_img})
    local baseline = img_list[idx][3].extrinsic.baseline
    --local scale_routing = PrecomputeScaleRouting(depth_img, baseline, img_list[idx][1], debug_dir)
    local scale_routing = PrecomputeScaleRouting(depth_img, baseline, img_list[idx][1], nil)

    local pyr_data = {}
    for j = 1, #img_sizes do
      --local scaled_img = image.scale(img, img_width, img_height, "bicubic")
      local scaled_img = img:clone()
      local width = img_sizes[j][1]
      local height = img_sizes[j][2]
      local orig_img_w, orig_img_h = scaled_img:size()
      if orig_img_w ~= width or orig_img_h ~= height then
        scaled_img:size(width, height)
      end
      scaled_img:save(save_debug .. img_list[idx][1]:sub(1,-5) .. '_' .. j .. '.png')
      local norm_img = scaled_img:toTensor('byte', 'RGB', 'DHW'):float()
      local num_channels = norm_img:size(1)
      for c = 1, num_channels do
        norm_img[c] = (norm_img[c] - norm_img[c]:mean()) / norm_img[c]:std()
      end
      --for c = 1, num_channels do
      --  norm_img[c] = norm_img[c] - vgg_rgb_mean[c]
      --end
      --table.insert(data, norm_img:view(1, num_channels, img_height, img_width))
      --table.insert(disp_data, gm.load(disp_dir .. imglist[i], 'byte')[1])
      --print(imglist[i])
      table.insert(pyr_data, norm_img:view(1, num_channels, height, width))
      --table.insert(labels, label_pyramid[j]:view(height, width))
    end
    table.insert(pyr_data, scale_routing)
    table.insert(data, pyr_data)
    table.insert(filenames, img_list[idx][1])

    if i % max_in_file == 0 or i == idx_shuffle:size(1) then
      torch.save(save_dir .. file_num .. '_' .. name .. "_data.t7", data)
      if has_gt then
        torch.save(save_dir .. file_num .. '_' .. name .. "_labels.t7", labels)
      end
      torch.save(save_dir .. file_num .. '_' .. name .. "_filenames.t7", filenames)        
      file_num = file_num + 1
      data = {}
      labels = {}
      filenames = {}
      collectgarbage()
    end
  end
end

local function PrepareDatasetWithSingleScale(name, max_in_file, has_gt)
  local rgb_subdir = rgb_dir .. name
  local gt_subdir = gt_dir .. name
  local save_dir = out_dir .. '/' .. name .. '/'
  local save_dir_single = out_dir .. '/single_scale/' .. name .. '/'
  local save_debug = save_dir .. '/debug/'
  os.execute('mkdir -p ' .. save_dir)
  os.execute('mkdir -p ' .. save_dir_single)
  os.execute('mkdir -p ' .. save_debug)
  local file_num = 1
  local data = {}
  local labels = {}
  local filenames = {}
  local depth = {}
  local data_single = {}
  local img_list = torch.load(root_dir .. name .. '_img_list.t7', img_list)

  local idx_shuffle = torch.randperm(#img_list)

  for i = 1, idx_shuffle:size(1) do
    local idx = idx_shuffle[i]
    local img_path = name .. '/' .. img_list[idx][2]
    xlua.progress(i, idx_shuffle:size(1))

    --table.insert(data, norm_img:view(num_channels, img_height, img_width))
    ----table.insert(labels, label_img:view(img_height, img_width))
    --table.insert(labels, {label_img:view(img_height, img_width), class_weights})

    local img = gm.Image(rgb_dir .. img_path)
    local gt_img, scaled_gt_img, label_img, class_weights
    if has_gt then
      gt_img = image.load(gt_dir .. img_path, 3, 'byte')
      scaled_gt_img = image.scale(gt_img, first_width, first_height, "simple")
      label_img = torch.IntTensor(first_height, first_width)
      class_weights = ConvertLabelFormat(scaled_gt_img, class_color_map, num_classes, label_img)
      table.insert(labels, {label_img:view(1, first_height, first_width), class_weights})
    end
    local depth_img = gm.Image(depth_dir .. img_path)
    depth_img:size(target_width, target_height)
    depth_img = depth_img:toTensor('byte','RGB','DHW'):float()[1]
    depth_img:mul(disp_scale)
    local norm_depth = (depth_img - depth_img:mean()) / depth_img:std()
    table.insert(depth, {norm_depth, depth_img})
    local baseline = img_list[idx][3].extrinsic.baseline
    local scale_routing = PrecomputeScaleRouting(depth_img, baseline, img_list[idx][1], debug_dir)
    --local scale_routing = PrecomputeScaleRouting(depth_img, baseline, img_list[idx][1], nil)

    local pyr_data = {}
    for j = 1, #img_sizes do
      --local scaled_img = image.scale(img, img_width, img_height, "bicubic")
      local scaled_img = img:clone()
      local width = img_sizes[j][1]
      local height = img_sizes[j][2]
      local orig_img_w, orig_img_h = scaled_img:size()
      if orig_img_w ~= width or orig_img_h ~= height then
        scaled_img:size(width, height)
      end
      --scaled_img:save(save_debug .. img_list[idx][1]:sub(1,-5) .. '_' .. j .. '.png')
      local norm_img = scaled_img:toTensor('byte', 'RGB', 'DHW'):float()
      local num_channels = norm_img:size(1)
      for c = 1, num_channels do
        norm_img[c] = (norm_img[c] - norm_img[c]:mean()) / norm_img[c]:std()
      end
      --for c = 1, num_channels do
      --  norm_img[c] = norm_img[c] - vgg_rgb_mean[c]
      --end
      --table.insert(data, norm_img:view(1, num_channels, img_height, img_width))
      --table.insert(disp_data, gm.load(disp_dir .. imglist[i], 'byte')[1])
      --print(imglist[i])
      table.insert(pyr_data, norm_img:view(1, num_channels, height, width))
      if j == 1 then
        table.insert(data_single, norm_img:view(1, num_channels, height, width))
      end
      --table.insert(labels, label_pyramid[j]:view(height, width))
    end
    table.insert(pyr_data, scale_routing)
    table.insert(data, pyr_data)
    table.insert(filenames, img_list[idx][1])

    if i % max_in_file == 0 or i == idx_shuffle:size(1) then
      torch.save(save_dir .. file_num .. '_' .. name .. "_data.t7", data)
      torch.save(save_dir_single .. file_num .. '_' .. name .. "_data.t7", data_single)
      if has_gt then
        torch.save(save_dir .. file_num .. '_' .. name .. "_labels.t7", labels)
        torch.save(save_dir_single .. file_num .. '_' .. name .. "_labels.t7", labels)
      end
      torch.save(save_dir .. file_num .. '_' .. name .. "_filenames.t7", filenames)        
      torch.save(save_dir_single .. file_num .. '_' .. name .. "_filenames.t7", filenames)        
      file_num = file_num + 1
      data = {}
      data_single = {}
      labels = {}
      filenames = {}
      collectgarbage()
    end
  end
end

--local function PrepareRoutingData(name, max_in_file)
--  local rgb_subdir = rgb_dir .. name
--  local gt_subdir = gt_dir .. name
--  local save_dir = out_dir .. '/' .. name .. '/'
--  os.execute('mkdir -p ' .. save_dir)
--  local file_num = 1
--  local data = {}
--  local depth = {}
--  local labels = {}
--  local filenames = {}
--  local img_list = torch.load(root_dir .. name .. '_img_list.t7', img_list)
--
--  local idx_shuffle = torch.randperm(#img_list)
--
--  for i = 1, idx_shuffle:size(1) do
--    xlua.progress(i, idx_shuffle:size(1))
--    local idx = idx_shuffle[i]
--    local img_path = name .. '/' .. img_list[idx][2]
--
--    local depth_img = gm.Image(depth_dir .. img_path)
--    depth_img:size(target_width, target_height)
--    depth_img = depth_img:toTensor('byte','RGB','DHW'):float()[1]
--    depth_img:mul(disp_scale)
--    local baseline = img_list[idx][3].extrinsic.baseline
--    --local scale_routing = PrecomputeScaleRouting(depth_img, baseline, img_list[idx][1], debug_dir)
--    local scale_routing = PrecomputeScaleRouting(depth_img, baseline, img_list[idx][1], nil)
--
--    table.insert(pyr_data, scale_routing)
--
--    if i % max_in_file == 0 or i == idx_shuffle:size(1) then
--      torch.save(save_dir .. file_num .. '_' .. name .. "_data.t7", data)
--      torch.save(save_dir .. file_num .. '_' .. name .. "_labels.t7", labels)
--      torch.save(save_dir .. file_num .. '_' .. name .. "_filenames.t7", filenames)        
--      file_num = file_num + 1
--      data = {}
--      labels = {}
--      filenames = {}
--      collectgarbage()
--    end
--  end
--end


local max_in_file = 50
--local max_in_file = 300
--PrepareDataset("train", max_in_file, true)
--PrepareDataset("val", max_in_file, true)
PrepareDatasetWithSingleScale("val", max_in_file, true)
PrepareDatasetWithSingleScale("train", max_in_file, true)
--PrepareDataset("test", max_in_file, false)

