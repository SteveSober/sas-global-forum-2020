/********************************************************************************/
/*                Code for SAS Global Forum 2020 Super Demo SD403               */
/*                    Title: Image Classification Using SAS®                    */
/*                           Author: Brian R. Gaines                            */
/*                                                                              */
/* Description:                                                                 */
/*    This is the "complete" version of the code that covers an end-to-end      */
/*    image classification example, from loading your images to creating an     */
/*    analytic store that you can use to put the model into production.         */
/*                                                                              */
/* Notes:                                                                       */
/*    See the directory for this super demo in the SASGF 2020 GitHub repository */
/*    for more information.  Please feel free to contact the author if you have */
/*    questions or issues.                                                      */
/********************************************************************************/

/*********/
/* Setup */
/*********/

/*** Macro variable setup ***/
/* Specify file path to your images (such as the giraffe_dolphin_small example data) */
%let imagePath = /filePathToImages/giraffe_dolphin_small/;

/* Specify file path to the model files (.sas architecture file, pretrained weights, ImageNet labels) */
%let modelPath = /filePathToModelFiles/;   

/* Specify the caslib and table name for your image data table */
%let imageCaslibName = casuser;
%let imageTableName = images;

/* Specify the caslib and table name for the augmented training image data table */
%let imageTrainingCaslibName = &imageCaslibName;
%let imageTrainingTableName = &imageTableName.Augmented;

/* Specify the name of the caslib associated with &modelPath */
%let modelCaslibName = dlmodels;

/*** CAS setup ***/
/* Connect to a CAS server */
cas;
/* Automatically assign librefs */
caslib _all_ assign;



/**************************************************************/
/*                   Load and display images                  */
/* Modified version of code generated by the Load Images task */
/**************************************************************/

/* Create temporary caslib and libref for loading images */
caslib loadImagesTempCaslib datasource=(srctype="path") path="&imagePath" subdirs notactive;
libname _loadtmp cas caslib="loadImagesTempCaslib";
libname _tmpcas_ cas caslib="CASUSER";

/* Load images */
proc cas;
    session %sysfunc(getlsessref(_loadtmp));
    action image.loadImages result=casOutInfo / caslib="loadImagesTempCaslib" 
        recurse=TRUE labelLevels=-1 casOut={caslib="&imageCaslibName", 
        name="&imageTableName", replace=TRUE};

    /* Randomly select images to display */
    nRows=max(casOutInfo.OutputCasTables[1, "Rows"], 1);
    _sampPct_=min(5/nRows*100, 100);
    action sampling.srs / table={caslib="&imageCaslibName", 
        name="&imageTableName"}, sampPct=_sampPct_, display={excludeAll=TRUE}, 
        output={casOut={caslib="CASUSER", name="_tempDisplayTable_", replace=TRUE}, 
        copyVars={"_path_" , "_label_" , "_id_"}};
    run;
quit;

/* Display images */
data _tmpcas_._tempDisplayTable_;
    set _tmpcas_._tempDisplayTable_ end=eof;
    _labelID_=cat(_label_, ' (_id_=', _id_, ')');

    if _n_=1 then
        do;
            dcl odsout obj();
            obj.layout_gridded(columns: 4);
        end;
    obj.region();
    obj.format_text(text: _labelID_, just: "c", style_attr: 'font_size=9pt');
    obj.image(file: _path_, width: "128", height: "128");

    if eof then
        do;
            obj.layout_end();
        end;
run;

/* Print file paths for the displayed images and drop the temporary table */
proc cas;
    session %sysfunc(getlsessref(_tmpcas_));
    action table.fetch / table={caslib="CASUSER" name="_tempDisplayTable_"} 
        fetchvars={'_path_', '_label_', '_id_'};
    action table.dropTable / caslib="CASUSER" name="_tempDisplayTable_";
    run;
quit;

/* Remove temporary caslib and libref */
caslib loadImagesTempCaslib drop;
libname _loadtmp;
libname _tmpcas_;



/******************************/
/* Explore and process images */
/******************************/

/*** Explore images ***/
proc cas;
    /* Summarize images */
    action image.summarizeImages / table={caslib="&imageCaslibName", name="&imageTableName"};

    /* Label frequencies */
    action simple.freq / table={caslib="&imageCaslibName", name="&imageTableName", vars="_label_"};   
    run;
quit;

/*** Process images ***/
proc cas;
    /* Resize images to 224x224 */
    action image.processImages / table={caslib="&imageCaslibName", name="&imageTableName"}
                imageFunctions={{functionOptions={functionType='RESIZE', height=224, width=224}}}
                casOut={caslib="&imageCaslibName", name="&imageTableName", replace=TRUE};

    /* Shuffle images */
    action table.shuffle / table={caslib="&imageCaslibName", name="&imageTableName"}
                casOut={caslib="&imageCaslibName", name="&imageTableName", replace=TRUE};

    /* Partition images */
    action sampling.srs / table={caslib="&imageCaslibName", name="&imageTableName"}, sampPct=50, 
                partInd=TRUE output={casOut={caslib="&imageCaslibName", name="&imageTableName", replace=TRUE}, 
                copyVars="ALL"};
    run;
quit;

/*** Augment the training data ***/
proc cas;
    /* Create cropped images */
    action image.augmentImages / 
                table={caslib="&imageCaslibName", name="&imageTableName", where="_partind_=1"},
                cropList={{
                    x=0, 
                    y=0, 
                    width=200, 
                    height=200, 
                    stepSize=24,
                    outputWidth=224, 
                    outputHeight=224
                    sweepImage=TRUE}},
                casOut={caslib="&imageTrainingCaslibName", name="&imageTrainingTableName", replace=TRUE};

    /* Label frequencies */
    action simple.freq / table={caslib="&imageTrainingCaslibName", name="&imageTrainingTableName", vars="_label_"};   
    run;
quit;



/****************************************/
/*** Build and train Simple CNN model ***/
/****************************************/

/*** Build model architecture ***/
proc cas;
    /* Use the channel means as offsets */
    action image.summarizeImages result=summary / 
                table={caslib="&imageTrainingCaslibName", name="&imageTrainingTableName"};
    offsetsTraining=summary.Summary[1, {"mean1stChannel","mean2ndChannel", "mean3rdChannel"}];

    /* Create empty deep learning model */
    action deepLearn.buildModel / 
                modelTable={name="Simple_CNN", replace=TRUE} type="CNN";
    /* Add input layer */
    action deepLearn.addLayer / 
                model="Simple_CNN"
                name="data"
                layer={type='input', nchannels=3, width=224, height=224, offsets=offsetsTraining};
    /* Add convolutional layer */
    action deepLearn.addLayer / 
                model="Simple_CNN"
                name="conv1"
                layer={type='convo', act="relu", nFilters=8, width=7, height=7, stride=1}
                srcLayers={'data'};
    /* Add pooling layer */
    action deepLearn.addLayer / 
                model="Simple_CNN" 
                name="pool1"
                layer={type='pool', pool='max', width=2, height=2, stride=2}
                srcLayers={'conv1'};
    /* Add convolutional layer */
    action deepLearn.addLayer / 
                model="Simple_CNN" 
                name="conv2"
                layer={type='convo', act="relu", nFilters=8, width=7, height=7, stride=1} 
                srcLayers={'pool1'};
    /* Add pooling layer */
    action deepLearn.addLayer / 
                model="Simple_CNN"
                name="pool2"
                layer={type='pool', pool='max', width=2, height=2, stride=2} 
                srcLayers={'conv2'};
    /* Add fully connected (fc) layer */
    action deepLearn.addLayer / 
                model="Simple_CNN"
                name="fc1"
                layer={type='fc', n=16, act='relu', init='xavier', includeBias='true'}
                srcLayers={'pool2'};
    /* Add output layer */
    action deepLearn.addLayer / 
                model="Simple_CNN"
                name="output"
                layer={type='output', n=2, act='softmax'} 
                srcLayers={'fc1'};
    run;
quit;


/*** Train model with augmented training data ***/
proc cas;
    action deepLearn.dlTrain / 
                table={caslib="&imageTrainingCaslibName", 
                       name="&imageTrainingTableName"} 
                model='Simple_CNN' 
                modelWeights={name='Simple_CNN_weights', 
                              replace=1}
                inputs='_image_' 
                target='_label_' nominal='_label_'
                optimizer={minibatchsize=2, 
                           algorithm={learningrate=0.0001},
                           maxepochs=10,
                           loglevel=2} 
                seed=12345;
    run;
quit; 

/*** Score validation set with trained model ***/
proc cas;
    action deepLearn.dlScore / 
                table={caslib="&imageCaslibName", name="&imageTableName", where="_partind_=0"} 
                model='Simple_CNN' 
                initWeights={name='Simple_CNN_weights'}
                casout={caslib="&imageTrainingCaslibName", name='imagesScoredSimpleCNN', replace=1}
                copyVars={'_label_', '_id_'};
    run;
quit;

/*** Create confusion matrix to assess performance ***/
proc cas;
   action simple.crossTab /
                row="_label_",
                col="_DL_PredName_",
                table={caslib="&imageTrainingCaslibName", name='imagesScoredSimpleCNN'};
    run;
quit;



/***************************************/
/*** Transfer learning with ResNet50 ***/
/***************************************/

/*** Setup ***/
/* Create caslib with model files */
caslib &modelCaslibName datasource=(srctype="path") path="&modelPath" subdirs notactive;

/*** Build model architecture (using .sas file) ***/
proc cas; 
    /* Include code to define ResNet50 architecture */
    ods exclude all;
    %include "&modelPath.model_resnet50_sgf.sas";
    ods exclude none;

    /* View model information */
    action deepLearn.modelInfo /                              
                modelTable={name="ResNet50"};
    run;
quit; 
    
/*** Import Caffe weights (in HDF5 format) ***/
proc cas;
	/* Load table containing ImageNet labels */
	/* Not used in this example but here for demonstration */
	action table.loadTable / 
                caslib="&modelCaslibName"
                path='newlabel.sas7bdat'
                casout={caslib="&modelCaslibName", name='imagenetlabels', replace=1}
                importoptions={filetype='basesas'};

	/* Import pretrained weights */
    action deepLearn.dlImportModelWeights /                        
                modelTable={name="ResNet50"} 
                modelWeights={name='ResNet50_weights', replace=1}
                formatType="caffe"
                weightFileCaslib="&modelCaslibName"
                weightFilePath="ResNet-50-model.caffemodel.h5"
                labelTable={caslib="&modelCaslibName", name='imagenetlabels', vars={'levid','levname'}};
    run;
quit;

/*** Change output layer to have the correct number of classes ***/
proc cas;
    /* Remove trained output layer */
    action deepLearn.removeLayer / 
                modelTable={name="ResNet50"} 
                name="fc1000";

    /* Add output layer with correct number of classes */
    action deepLearn.addLayer / 
                model={name="ResNet50"} 
                name="fc2"
                layer={type="output", n=2, act="softmax"} 
                srcLayers={"pool5"};                  
    run;
quit;

/*** Train model with augmented training data, initialize with pretrained ResNet50 weights ***/
proc cas;
    action deepLearn.dlTrain / 
                table={caslib="&imageTrainingCaslibName", name="&imageTrainingTableName"}
                model={name="ResNet50"} 
                initWeights={name='ResNet50_weights'}
                modelWeights={name='ResNet50_weights_giraffe', replace=1}
                inputs='_image_' 
                target='_label_' nominal={'_label_'}
                optimizer={minibatchsize=1, 
                           algorithm={method='VANILLA', learningrate=5E-3}
                           maxepochs=5,
                           loglevel=3} 
                seed=12345;
    run;
quit;

/*** Score validation set with trained model ***/
proc cas;
    action deepLearn.dlScore / 
                table={caslib="&imageCaslibName", name="&imageTableName", where="_partind_=0"} 
                model={name="ResNet50"} 
                initWeights={name='ResNet50_weights_giraffe'}
                casout={caslib="&imageTrainingCaslibName", name='imagesScoredResNet50', replace=1}
                copyVars={'_label_', '_id_'};
    run;
quit;

/*** Create confusion matrix to assess performance ***/
proc cas;
    action simple.crossTab /
                table={caslib="&imageTrainingCaslibName", name='imagesScoredResNet50'},
                row="_label_",
                col="_DL_PredName_";
    run;
quit;



/************************/
/*** Model Deployment ***/
/************************/

/*** Create analytic store (astore) table to put model into production ***/
proc cas;
    action deepLearn.dlExportModel /                                
                modelTable={name="ResNet50"}
                initWeights={name="ResNet50_weights_giraffe"}
                casOut={name="ResNet50_giraffe"};
    run;
quit;