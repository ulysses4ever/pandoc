{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{- |
Module      : Text.Pandoc.Writers.Docx.Table
Copyright   : Copyright (C) 2012-2021 John MacFarlane
License     : GNU GPL, version 2 or above
Maintainer  : John MacFarlane <jgm@berkeley.edu>

Conversion of table blocks to docx.
-}
module Text.Pandoc.Writers.Docx.Table
  ( tableToOpenXML
  ) where

import Control.Monad.State.Strict
import Data.Array
import Data.Text (Text)
import Text.Pandoc.Definition
import Text.Pandoc.Class.PandocMonad (PandocMonad)
import Text.Pandoc.Writers.Docx.Types
import Text.Pandoc.Shared
import Text.Printf (printf)
import Text.Pandoc.Writers.GridTable hiding (Table)
import Text.Pandoc.Writers.OOXML
import Text.Pandoc.XML.Light as XML hiding (Attr)
import qualified Data.Text as T
import qualified Text.Pandoc.Writers.GridTable as Grid

tableToOpenXML :: PandocMonad m
               => ([Block] -> WS m [Content])
               -> Grid.Table
               -> WS m [Content]
tableToOpenXML blocksToOpenXML gridTable = do
  setFirstPara
  modify $ \s -> s { stInTable = True }
  let (Grid.Table _attr caption colspecs _rowheads thead tbodies tfoot) =
        gridTable
  let (Caption _maybeShortCaption captionBlocks) = caption
  let captionStr = stringify captionBlocks
  captionXml <- if null captionBlocks
                then return []
                else withParaPropM (pStyleM "Table Caption")
                     $ blocksToOpenXML captionBlocks
  head' <- cellGridToOpenXML blocksToOpenXML HeadRow thead
  bodies <- mapM (cellGridToOpenXML blocksToOpenXML BodyRow) tbodies
  foot' <- cellGridToOpenXML blocksToOpenXML FootRow tfoot

  let hasHeader = not . null . indices . partRowAttrs $ thead
  let hasFooter = not . null . indices . partRowAttrs $ tfoot
  -- for compatibility with Word <= 2007, we include a val with a bitmask
  -- 0×0020  Apply first row conditional formatting
  -- 0×0040  Apply last row conditional formatting
  -- 0×0080  Apply first column conditional formatting
  -- 0×0100  Apply last column conditional formatting
  -- 0×0200  Do not apply row banding conditional formatting
  -- 0×0400  Do not apply column banding conditional formattin
  let tblLookVal = if hasHeader then (0x20 :: Int) else 0
  let (gridCols, tblWattr) = tableLayout (elems colspecs)
  let tbl = mknode "w:tbl" []
        ( mknode "w:tblPr" []
          ( mknode "w:tblStyle" [("w:val","Table")] () :
            mknode "w:tblW" tblWattr () :
            mknode "w:tblLook" [("w:firstRow",if hasHeader then "1" else "0")
                               ,("w:lastRow",if hasFooter then "1" else "0")
                               ,("w:firstColumn","0")
                               ,("w:lastColumn","0")
                               ,("w:noHBand","0")
                               ,("w:noVBand","0")
                               ,("w:val", T.pack $ printf "%04x" tblLookVal)
                               ] () :
            [ mknode "w:tblCaption" [("w:val", captionStr)] ()
            | not (T.null captionStr) ]
          )
          : mknode "w:tblGrid" [] gridCols
          : head' ++ mconcat bodies ++ foot'
        )
  modify $ \s -> s { stInTable = False }
  return $ captionXml ++ [Elem tbl]

-- | Parts of a table
data RowType = HeadRow | BodyRow | FootRow

alignmentToString :: Alignment -> Text
alignmentToString = \case
  AlignLeft    -> "left"
  AlignRight   -> "right"
  AlignCenter  -> "center"
  AlignDefault -> "left"

tableLayout :: [ColSpec] -> ([Element], [(Text, Text)])
tableLayout specs =
  let
    textwidth = 7920  -- 5.5 in in twips       (1 twip == 1/20 pt)
    fullrow   = 5000  -- 100% specified in pct (1 pct  == 1/50th of a percent)
    ncols = length specs
    getWidth = \case
      ColWidth n -> n
      _          -> 0
    widths = map (getWidth . snd) specs
    rowwidth  = round (fullrow * sum widths) :: Int
    widthToTwips w = floor (textwidth * w)   :: Int
    mkGridCol w = mknode "w:gridCol" [("w:w", tshow (widthToTwips w))] ()
  in if all (== 0) widths
     then ( replicate ncols $ mkGridCol (1.0 / fromIntegral ncols)
          , [ ("w:type", "auto"), ("w:w", "0")])
     else ( map mkGridCol widths
          , [ ("w:type", "pct"), ("w:w", tshow rowwidth) ])

cellGridToOpenXML :: PandocMonad m
                  => ([Block] -> WS m [Content])
                  -> RowType
                  -> Part
                  -> WS m [Element]
cellGridToOpenXML blocksToOpenXML rowType part@(Part _ _ rowAttrs) =
  if null (indices rowAttrs)
  then return mempty
  else mapM (rowToOpenXML blocksToOpenXML) $ partToRows rowType part

data OOXMLCell
  = OOXMLCell Attr Alignment RowSpan ColSpan [Block]
  | OOXMLCellMerge ColSpan

data OOXMLRow = OOXMLRow RowType Attr [OOXMLCell]

partToRows :: RowType -> Part -> [OOXMLRow]
partToRows rowType part =
  let
    toOOXMLCell :: RowIndex -> ColIndex -> GridCell -> [OOXMLCell]
    toOOXMLCell ridx cidx = \case
      ContentCell attr align rowspan colspan blocks ->
        [OOXMLCell attr align rowspan colspan blocks]
      ContinuationCell idx'@(ridx',cidx') | ridx /= ridx', cidx == cidx' ->
        case (partCellArray part)!idx' of
          (ContentCell _ _ _ colspan _) -> [OOXMLCellMerge colspan]
          x -> error $ "Content cell expected, got, " ++ show x ++
                       " at index " ++ show idx'
      _ -> mempty
    mkRow :: (RowIndex, Attr) -> OOXMLRow
    mkRow (ridx, attr) = OOXMLRow rowType attr
                       . concatMap (uncurry $ toOOXMLCell ridx)
                       . assocs
                       . rowArray ridx
                       $ partCellArray part
  in map mkRow $ assocs (partRowAttrs part)

rowToOpenXML :: PandocMonad m
             => ([Block] -> WS m [Content])
             -> OOXMLRow
             -> WS m Element
rowToOpenXML blocksToOpenXML (OOXMLRow rowType _attr cells) = do
  xmlcells <- mapM (ooxmlCellToOpenXML blocksToOpenXML) cells
  let addTrPr = case rowType of
        HeadRow -> (mknode "w:trPr" []
                    [mknode "w:tblHeader" [("w:val", "true")] ()] :)
        BodyRow -> id
        FootRow -> id
  -- let align' = case align of
  --       AlignDefault -> colAlign
  --       _            -> align
  return $ mknode "w:tr" [] (addTrPr xmlcells)

ooxmlCellToOpenXML :: PandocMonad m
                   => ([Block] -> WS m [Content])
                   -> OOXMLCell
                   -> WS m Element
ooxmlCellToOpenXML blocksToOpenXML = \case
  OOXMLCellMerge (ColSpan colspan) -> do
    return $ mknode "w:tc" []
      [ mknode "w:tcPr" [] [ mknode "w:gridSpan" [("w:val", tshow colspan)] ()
                           , mknode "w:vMerge"   [("w:val", "continue")] () ]
      , mknode "w:p" [] [mknode "w:pPr" [] ()]]
  OOXMLCell _attr align rowspan (ColSpan colspan) contents -> do
    compactStyle <- pStyleM "Compact"
    es <- withParaProp (alignmentFor align) $ blocksToOpenXML contents
    -- Table cells require a <w:p> element, even an empty one!
    -- Not in the spec but in Word 2007, 2010. See #4953. And
    -- apparently the last element must be a <w:p>, see #6983.
    return . mknode "w:tc" [] $
      Elem
       (mknode "w:tcPr" [] ([ mknode "w:gridSpan" [("w:val", tshow colspan)] ()
                            | colspan > 1] ++
                            [ mknode "w:vMerge" [("w:val", "restart")] ()
                            | rowspan > RowSpan 1 ])) :
      if null contents
      then [Elem $ mknode "w:p" [] [mknode "w:pPr" [] [compactStyle]]]
      else case reverse (onlyElems es) of
             b:e:_ | qName (elName b) == "bookmarkEnd"  -- y tho?
                   , qName (elName e) == "p" -> es
             e:_   | qName (elName e) == "p" -> es
             _ -> es ++ [Elem $ mknode "w:p" [] ()]

alignmentFor :: Alignment -> Element
alignmentFor al = mknode "w:jc" [("w:val",alignmentToString al)] ()
