<?php

namespace OPNsense\AmneziaWG;

class IndexController extends PageControllerBase
{
    public function indexAction()
    {
        return $this->response->redirect('/ui/amneziawg/general');
    }
}
